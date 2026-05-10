/**
 * Haven Voice Protocol — Client Library
 *
 * Connects to Haven voice channels via WebRTC (P2P audio/video) with
 * Socket.IO signaling for join/leave, SDP exchange, and ICE relay.
 *
 * Usage:
 *   const vc = new HavenVoice({ socket, token });
 *   await vc.join(channelCode);
 *   // vc.on('speaking', (userId, speaking) => …)
 *   // vc.on('track', (userId, stream) => …)
 */
'use strict';

// ──────────────────────────────────────────────────────────
// Constants
// ──────────────────────────────────────────────────────────

const CHANNEL_CODE_RE = /^[a-f0-9]{8}$/i;
const MAX_SDP_SIZE = 16384;
const MAX_ICE_SIZE = 2048;

// ──────────────────────────────────────────────────────────
// Events emitted by this class
// ──────────────────────────────────────────────────────────
// 'connected'         — joined the voice channel successfully
// 'disconnected'      — left the channel or connection lost
// 'speaking'          — (userId, isSpeaking)
// 'track'             — (userId, stream, kind)  kind: 'voice' | 'screen' | 'webcam'
// 'user-joined'       — (userId, username)
// 'user-left'         — (userId, username)
// 'screen-share-started'  — (userId, username)
// 'screen-share-stopped'  — (userId)
// 'webcam-started'        — (userId, username)
// 'webcam-stopped'        — (userId)
// 'deafened'          — (isDeafened)
// 'muted'             — (isMuted)
// 'error'             — (error)
// 'ice-servers'       — (iceServers)
// 'voice-bitrate'     — (bitrate)
// 'music-play'        — (userId, username, url, title, trackId, syncState)
// 'music-queue'       — (queue)
// 'stream-viewers'    — (streams)  streams: [{ sharerId, sharerName, viewers: [{id, username}] }]
// 'afk-move'          — (channelCode)
// 'kicked'            — (channelCode, reason)

// ──────────────────────────────────────────────────────────
// HavenVoice — public API
// ──────────────────────────────────────────────────────────

class HavenVoice {
  /**
   * @param {object} opts
   * @param {import('socket.io-client').Socket} opts.socket — authenticated Socket.IO instance
   * @param {string} opts.token — Bearer token for REST endpoints
   * @param {string[]} [opts.iceServers] — optional ICE servers (bypasses /api/ice-servers)
   * @param {number} [opts.audioBitrate] — optional audio bitrate cap in kbps
   */
  constructor(opts) {
    this.socket = opts.socket;
    this.token = opts.token;
    this.audioBitrate = opts.audioBitrate || 0;

    // ICE config
    this.rtcConfig = {
      iceServers: opts.iceServers || [
        { urls: 'stun:stun.stunprotocol.org:3478' },
        { urls: 'stun:stun.nextcloud.com:3478' }
      ]
    };

    // State
    this.currentChannel = null;
    this.inVoice = false;
    this.isMuted = false;
    this.isDeafened = false;

    // Peer connections: userId → { connection, stream, username }
    this.peers = new Map();

    // Screen/webcam tracking: userId → true
    this.screenSharers = new Set();
    this.webcamUsers = new Set();

    // Web Audio
    this.audioCtx = null;
    this.gainNodes = new Map();
    this.screenGainNodes = new Map();
    this.rawStream = null;
    this.localStream = null;

    // Noise suppression
    this.noiseMode = 'gate';
    this.noiseSensitivity = 10;
    this._rnnoiseNode = null;
    this._rnnoiseReady = false;
    this._rnnoiseSource = null;
    this._noiseGateGain = null;
    this._noiseGateAnalyser = null;
    this._noiseGateInterval = null;
    this._vcDest = null;

    // Screen share
    this.screenStream = null;
    this.isScreenSharing = false;
    this.screenResolution = 1080;
    this.screenFrameRate = 30;
    this._screenBitrates = {
      0:    4_000_000,
      720:  1_500_000,
      1080: 3_000_000,
      1440: 5_000_000
    };

    // Webcam
    this.webcamStream = null;
    this.isWebcamActive = false;

    // Disconnect recovery
    this._disconnectTimers = {};

    // Pending ICE candidates (arrived before peer created)
    this._pendingCandidatesByUser = null;

    // User IDs for track classification
    this._localUserId = null;

    this._setupSocketListeners();
    this._fetchIceServers();
  }

  // ── ICE Servers ──────────────────────────────────────────

  async _fetchIceServers() {
    try {
      const res = await fetch('/api/ice-servers', {
        headers: { 'Authorization': `Bearer ${this.token}` }
      });
      if (res.ok) {
        const data = await res.json();
        if (data.iceServers?.length) {
          this.rtcConfig.iceServers = data.iceServers;
          this.emit('ice-servers', data.iceServers);
        }
      }
    } catch (err) {
      this.emit('error', err);
    }
  }

  // ── Socket Event Setup ───────────────────────────────────

  _setupSocketListeners() {
    // ── Incoming ──────────────────────────────────────────

    this.socket.on('voice-existing-users', async (data) => {
      this.currentChannel = data.channelCode;
      this.audioBitrate = data.voiceBitrate || 0;
      for (const user of data.users) {
        await this._createPeer(user.id, user.username, true);
      }
      this.emit('connected', { channelCode: data.channelCode, users: data.users });
    });

    this.socket.on('voice-user-joined', (data) => {
      if (data?.user) this.emit('user-joined', data.user.id, data.user.username);
    });

    this.socket.on('voice-offer', async (data) => {
      const { from, offer } = data;
      let peer = this.peers.get(from.id);
      if (peer) {
        const cs = peer.connection.connectionState;
        const ics = peer.connection.iceConnectionState;
        if (cs === 'failed' || cs === 'closed' || ics === 'failed' || ics === 'closed') {
          this._removePeer(from.id);
          peer = null;
        }
      }
      if (!peer) {
        await this._createPeer(from.id, from.username, false);
        peer = this.peers.get(from.id);
        if (peer && this._pendingCandidatesByUser?.has(from.id)) {
          peer._pendingCandidates = (peer._pendingCandidates || []).concat(
            this._pendingCandidatesByUser.get(from.id)
          );
          this._pendingCandidatesByUser.delete(from.id);
        }
      }
      try {
        const conn = peer.connection;
        if (conn.signalingState !== 'stable') {
          await conn.setLocalDescription({ type: 'rollback' });
        }
        await conn.setRemoteDescription(new RTCSessionDescription(offer));
        const answer = await conn.createAnswer();
        await conn.setLocalDescription(answer);
        this.socket.emit('voice-answer', {
          code: this.currentChannel,
          targetUserId: from.id,
          answer
        });
        if (peer._pendingCandidates?.length) {
          for (const c of peer._pendingCandidates) {
            try { await conn.addIceCandidate(new RTCIceCandidate(c)); } catch {}
          }
          peer._pendingCandidates = [];
        }
      } catch (err) {
        this.emit('error', err);
      }
    });

    this.socket.on('voice-answer', async (data) => {
      const peer = this.peers.get(data.from.id);
      if (peer) {
        try {
          if (peer.connection.signalingState === 'have-local-offer') {
            await peer.connection.setRemoteDescription(new RTCSessionDescription(data.answer));
            if (peer._pendingCandidates?.length) {
              for (const c of peer._pendingCandidates) {
                try { await peer.connection.addIceCandidate(new RTCIceCandidate(c)); } catch {}
              }
              peer._pendingCandidates = [];
            }
          }
        } catch (err) { this.emit('error', err); }
      }
    });

    this.socket.on('voice-ice-candidate', async (data) => {
      const peer = this.peers.get(data.from.id);
      if (!data.candidate) return;
      if (peer) {
        if (!peer.connection.remoteDescription) {
          (peer._pendingCandidates ||= []).push(data.candidate);
          return;
        }
        try { await peer.connection.addIceCandidate(new RTCIceCandidate(data.candidate)); }
        catch (err) { this.emit('error', err); }
      } else {
        (this._pendingCandidatesByUser ||= new Map());
        const list = this._pendingCandidatesByUser.get(data.from.id) || [];
        list.push(data.candidate);
        this._pendingCandidatesByUser.set(data.from.id, list);
      }
    });

    this.socket.on('voice-speaking', (data) => {
      if (data?.userId != null) {
        const uid = data.userId === this._localUserId ? 'self' : data.userId;
        this.emit('speaking', uid, !!data.speaking);
      }
    });

    this.socket.on('voice-user-left', (data) => {
      if (data?.user) {
        this.emit('user-left', data.user.id, data.user.username);
        this._stopAnalyser(data.user.id);
        this._removePeer(data.user.id);
      }
      if (data?.user && this.screenSharers.has(data.user.id)) {
        this.screenSharers.delete(data.user.id);
        this.emit('screen-share-stopped', data.user.id);
      }
      if (data?.user && this.webcamUsers.has(data.user.id)) {
        this.webcamUsers.delete(data.user.id);
        this.emit('webcam-stopped', data.user.id);
      }
    });

    this.socket.on('voice-bitrate-updated', (data) => {
      if (data?.code === this.currentChannel) {
        this.audioBitrate = data.bitrate || 0;
        for (const [, peer] of this.peers) this._applyAudioBitrate(peer.connection);
        this.emit('voice-bitrate', data.bitrate);
      }
    });

    this.socket.on('voice-afk-move', (data) => {
      if (!data?.channelCode) return;
      this.leave();
      this.emit('afk-move', data.channelCode);
    });

    this.socket.on('voice-kicked', (data) => {
      if (!data?.channelCode) return;
      if (this.currentChannel !== data.channelCode) return;
      this.leave();
      this.emit('kicked', data.channelCode, data.reason);
    });

    this.socket.on('screen-share-started', (data) => {
      this.screenSharers.add(data.userId);
      this.emit('screen-share-started', data.userId, data.username);
    });

    this.socket.on('screen-share-stopped', (data) => {
      this.screenSharers.delete(data.userId);
      this.emit('screen-share-stopped', data.userId);
    });

    this.socket.on('webcam-started', (data) => {
      this.webcamUsers.add(data.userId);
      this.emit('webcam-started', data.userId, data.username);
    });

    this.socket.on('webcam-stopped', (data) => {
      this.webcamUsers.delete(data.userId);
      this.emit('webcam-stopped', data.userId);
    });

    this.socket.on('active-screen-sharers', (data) => {
      if (data?.sharers) data.sharers.forEach(s => this.screenSharers.add(s.id));
    });

    this.socket.on('active-webcam-users', (data) => {
      if (data?.users) data.users.forEach(u => this.webcamUsers.add(u.id));
    });

    this.socket.on('renegotiate-screen', async (data) => {
      if (!this.screenStream || !this.isScreenSharing) return;
      const peer = this.peers.get(data.targetUserId);
      if (!peer) return;
      const conn = peer.connection;
      const senders = conn.getSenders();
      const screenTracks = this.screenStream.getTracks().filter(t => t.readyState === 'live');
      const missing = screenTracks.filter(track => !senders.some(s => s.track === track));
      if (missing.length) {
        missing.forEach(track => conn.addTrack(track, this.screenStream));
        const res = this.screenResolution;
        const maxBitrate = this._screenBitrates[res] || this._screenBitrates[0];
        this._applyScreenBitrate(conn, maxBitrate);
      }
      await this._renegotiate(data.targetUserId, conn);
    });

    this.socket.on('renegotiate-webcam', async (data) => {
      if (!this.webcamStream || !this.isWebcamActive) return;
      const peer = this.peers.get(data.targetUserId);
      if (!peer) return;
      const conn = peer.connection;
      const senders = conn.getSenders();
      const webcamTrack = this.webcamStream.getVideoTracks()[0];
      const alreadySent = webcamTrack && senders.some(s => s.track === webcamTrack);
      if (!alreadySent && webcamTrack) conn.addTrack(webcamTrack, this.webcamStream);
      await this._renegotiate(data.targetUserId, conn);
    });

    this.socket.on('music-shared', (data) => {
      this.emit('music-play',
        data.userId, data.username, data.url, data.title,
        data.trackId, data.syncState
      );
    });

    this.socket.on('music-queue-update', (data) => {
      this.emit('music-queue', data);
    });

    this.socket.on('stream-viewers-update', (data) => {
      this.emit('stream-viewers', data.streams);
    });

    this.socket.on('voice-users-update', (data) => {
      this.emit('voice-users', data.users);
    });

    this.socket.on('voice-count-update', (data) => {
      this.emit('voice-count', data);
    });

    this.socket.on('channel-members', (data) => {
      this.emit('channel-members', data.members);
    });

    // ── Emit events helper ────────────────────────────────

    // (EventEmitter-style, see _emit below)
  }

  // ── Event Emitter (minimal) ──────────────────────────────

  _events = {};
  on(event, fn) { (this._events[event] ||= []).push(fn); }
  off(event, fn) {
    if (!this._events[event]) return;
    this._events[event] = this._events[event].filter(f => f !== fn);
  }
  _emit(event, ...args) {
    const fns = this._events[event];
    if (fns) for (const fn of fns) fn(...args);
  }
  // Alias for convenience
  emit = this._emit;

  // ── Public API ───────────────────────────────────────────

  /**
   * Join a voice channel.
   * @param {string} channelCode — 8-char hex channel code
   * @returns {Promise<boolean>} success
   */
  async join(channelCode) {
    try {
      const preservedMute = this.isMuted;
      const preservedDeafen = this.isDeafened;

      if (this.inVoice) this.leave();

      await this._fetchIceServers();
      this._ensureAudioCtx();
      await this.audioCtx.resume().catch(() => {});

      const savedInputId = localStorage.getItem('haven_input_device') || '';
      const audioConstraints = {
        echoCancellation: true,
        noiseSuppression: true,
        autoGainControl: true
      };
      if (savedInputId) audioConstraints.deviceId = { exact: savedInputId };

      try {
        this.rawStream = await navigator.mediaDevices.getUserMedia({
          audio: audioConstraints,
          video: false
        });
      } catch (deviceErr) {
        if (savedInputId) {
          console.warn('Saved mic device failed, falling back to default:', deviceErr.message);
          localStorage.removeItem('haven_input_device');
          delete audioConstraints.deviceId;
          this.rawStream = await navigator.mediaDevices.getUserMedia({
            audio: audioConstraints,
            video: false
          });
        } else {
          throw deviceErr;
        }
      }

      // Noise gate chain
      const source = this.audioCtx.createMediaStreamSource(this.rawStream);
      this._rnnoiseSource = source;
      const gateAnalyser = this.audioCtx.createAnalyser();
      gateAnalyser.fftSize = 2048;
      gateAnalyser.smoothingTimeConstant = 0.3;
      source.connect(gateAnalyser);

      const gateGain = this.audioCtx.createGain();
      source.connect(gateGain);

      const dest = this.audioCtx.createMediaStreamDestination();
      gateGain.connect(dest);

      this._noiseGateAnalyser = gateAnalyser;
      this._noiseGateGain = gateGain;
      this._vcDest = dest;
      this.localStream = dest.stream;
      this._startNoiseGate();

      // RNNoise
      await this._initRNNoise();
      if (this.noiseMode === 'suppress' && this._rnnoiseReady) {
        this.setNoiseSensitivity(0);
        this._enableRNNoise();
      } else if (this.noiseMode === 'gate') {
        this.setNoiseSensitivity(this.noiseSensitivity);
      }

      this.currentChannel = channelCode;
      this.inVoice = true;
      this.isMuted = preservedMute;
      this.isDeafened = preservedDeafen;
      this._applyMuteStateToLocalTracks();

      this.socket.emit('voice-join', { code: channelCode });

      this._startLocalTalkDetection();

      return true;
    } catch (err) {
      this.emit('error', err);
      return false;
    }
  }

  /**
   * Leave the current voice channel.
   */
  leave() {
    if (this.isScreenSharing) this.stopScreenShare();
    if (this.isWebcamActive) this.stopWebcam();

    this._disableRNNoise();
    this._stopNoiseGate();
    this._stopLocalTalkDetection();
    for (const [id] of this.analysers) this._stopAnalyser(id);

    const leavingChannel = this.currentChannel;

    if (leavingChannel) {
      let acked = false;
      this.socket.emit('voice-leave', { code: leavingChannel }, () => { acked = true; });
      setTimeout(() => {
        if (acked) return;
        if (!this.socket.connected) return;
        if (this.inVoice || this.currentChannel) return;
        this.socket.emit('voice-leave', { code: leavingChannel });
      }, 2000);
    }

    for (const [id] of this.peers) this._removePeer(id);
    this.gainNodes.clear();
    this.screenGainNodes.clear();

    if (this.rawStream) {
      this.rawStream.getTracks().forEach(t => t.stop());
      this.rawStream = null;
    }
    if (this.localStream) {
      this.localStream.getTracks().forEach(t => t.stop());
      this.localStream = null;
    }

    this.currentChannel = null;
    this.inVoice = false;
    this.isMuted = false;
    this.isDeafened = false;
    this.audioBitrate = 0;
    this.screenSharers.clear();
    this.webcamUsers.clear();
    this._vcDest = null;

    if (this.audioCtx) {
      this.audioCtx.close().catch(() => {});
      this.audioCtx = null;
    }

    if (this._disconnectTimers) {
      for (const key of Object.keys(this._disconnectTimers)) {
        clearTimeout(this._disconnectTimers[key]);
      }
      this._disconnectTimers = {};
    }

    this.emit('disconnected');
  }

  /**
   * Toggle mute.
   * @returns {boolean} new mute state
   */
  toggleMute() {
    this.isMuted = !this.isMuted;
    this._applyMuteStateToLocalTracks();
    this.socket.emit('voice-mute-state', { code: this.currentChannel, muted: this.isMuted });
    this.emit('muted', this.isMuted);
    return this.isMuted;
  }

  /**
   * Toggle deafen (mute all incoming audio).
   * @returns {boolean} new deafen state
   */
  toggleDeafen() {
    this.isDeafened = !this.isDeafened;
    for (const [, gainNode] of this.gainNodes) {
      gainNode.gain.value = this.isDeafened ? 0 : this._getSavedVolume(gainNode._userId || 0);
    }
    for (const [userId, gainNode] of this.screenGainNodes) {
      gainNode.gain.value = this.isDeafened ? 0 : this._getSavedStreamVolume(userId);
    }
    document.querySelectorAll('#audio-container audio').forEach(el => {
      if (this.isDeafened) {
        el.dataset.prevVolume = el.volume;
        el.volume = 0;
      } else {
        el.volume = parseFloat(el.dataset.prevVolume || 1);
      }
    });
    this.emit('deafened', this.isDeafened);
    return this.isDeafened;
  }

  /**
   * Set volume for a specific peer.
   * @param {string|number} userId
   * @param {number} volume — 0..2 (2 = 200% boost)
   */
  setVolume(userId, volume) {
    const gainNode = this.gainNodes.get(userId);
    if (gainNode) {
      gainNode.gain.value = Math.max(0, Math.min(2, volume));
    } else {
      const audioEl = document.getElementById(`voice-audio-${userId}`);
      if (audioEl) audioEl.volume = Math.max(0, Math.min(1, volume));
    }
  }

  // ── Screen Sharing ───────────────────────────────────────

  /**
   * Start screen sharing.
   * @returns {Promise<boolean>}
   */
  async shareScreen() {
    if (!this.inVoice || this.isScreenSharing) return false;
    try {
      const videoConstraints = { cursor: 'always' };
      const res = this.screenResolution;
      const fps = this.screenFrameRate;

      if (res && res !== 0) {
        const widths = { 720: 1280, 1080: 1920, 1440: 2560 };
        videoConstraints.width = { ideal: widths[res] || 1920 };
        videoConstraints.height = { ideal: res };
      }
      videoConstraints.frameRate = { ideal: fps };

      const displayMediaOptions = { video: videoConstraints, audio: true };

      const isElectron = !!(window.havenDesktop || navigator.userAgent.includes('Electron'));
      if (!isElectron) {
        displayMediaOptions.surfaceSwitching = 'exclude';
        displayMediaOptions.selfBrowserSurface = 'include';
        displayMediaOptions.monitorTypeSurfaces = 'include';
        if (typeof CaptureController !== 'undefined') {
          this._captureController = new CaptureController();
          displayMediaOptions.controller = this._captureController;
        }
      }

      this.screenStream = await navigator.mediaDevices.getDisplayMedia(displayMediaOptions);
      this.isScreenSharing = true;

      this.screenStream.getVideoTracks()[0].onended = () => this.stopScreenShare();

      const screenAudioTrack = this.screenStream.getAudioTracks()[0];
      if (screenAudioTrack) screenAudioTrack.onended = () => { /* screenHasAudio = false */ };

      const hasAudio = this.screenStream.getAudioTracks().length > 0;
      this.socket.emit('screen-share-started', { code: this.currentChannel, hasAudio });

      const maxBitrate = this._screenBitrates[res] || this._screenBitrates[0];
      for (const [userId, peer] of this.peers) {
        this.screenStream.getTracks().forEach(track => {
          peer.connection.addTrack(track, this.screenStream);
        });
        this._applyScreenBitrate(peer.connection, maxBitrate);
        await this._renegotiate(userId, peer.connection);
      }

      return true;
    } catch (err) {
      this.emit('error', err);
      this.isScreenSharing = false;
      this.screenStream = null;
      return false;
    }
  }

  /**
   * Stop screen sharing.
   */
  async stopScreenShare() {
    if (!this.isScreenSharing || !this.screenStream) return;

    const tracks = this.screenStream.getTracks();
    const renegotiations = [];
    for (const [userId, peer] of this.peers) {
      const senders = peer.connection.getSenders();
      tracks.forEach(track => {
        const sender = senders.find(s => s.track === track);
        if (sender) {
          try { peer.connection.removeTrack(sender); } catch {}
        }
      });
      renegotiations.push(this._renegotiate(userId, peer.connection).catch(() => {}));
    }

    try {
      await Promise.race([
        Promise.all(renegotiations),
        new Promise(resolve => setTimeout(resolve, 3000))
      ]);
    } catch {}

    tracks.forEach(t => t.stop());
    this.screenStream = null;
    this.isScreenSharing = false;
    this._captureController = null;

    this.socket.emit('screen-share-stopped', { code: this.currentChannel });
  }

  /**
   * Set screen share resolution (0 = source, 720, 1080, 1440).
   */
  setScreenResolution(h) {
    this.screenResolution = h;
    localStorage.setItem('haven_screen_res', h);
    if (this.isScreenSharing) this._applyLiveQualityChange();
  }

  /**
   * Set screen share frame rate (15, 30, 60).
   */
  setScreenFrameRate(fps) {
    this.screenFrameRate = fps;
    localStorage.setItem('haven_screen_fps', fps);
    if (this.isScreenSharing) this._applyLiveQualityChange();
  }

  async _applyLiveQualityChange() {
    if (!this.screenStream) return;
    const videoTrack = this.screenStream.getVideoTracks()[0];
    if (!videoTrack) return;

    const res = this.screenResolution;
    const fps = this.screenFrameRate;
    const constraints = {};
    if (res && res !== 0) {
      const widths = { 720: 1280, 1080: 1920, 1440: 2560 };
      constraints.width = { ideal: widths[res] || 1920 };
      constraints.height = { ideal: res };
    }
    constraints.frameRate = { ideal: fps };

    try { await videoTrack.applyConstraints(constraints); } catch (e) {
      console.warn('applyConstraints failed:', e);
    }

    const maxBitrate = this._screenBitrates[res] || this._screenBitrates[0];
    for (const [, peer] of this.peers) {
      this._applyScreenBitrate(peer.connection, maxBitrate);
    }
  }

  // ── Webcam ───────────────────────────────────────────────

  /**
   * Start webcam.
   * @returns {Promise<boolean>}
   */
  async startWebcam() {
    if (!this.inVoice || this.isWebcamActive) return false;
    try {
      const savedCamId = localStorage.getItem('haven_cam_device') || '';
      const videoConstraints = {
        width: { ideal: 640 },
        height: { ideal: 480 },
        frameRate: { ideal: 30 }
      };
      if (savedCamId) videoConstraints.deviceId = { exact: savedCamId };

      this.webcamStream = await navigator.mediaDevices.getUserMedia({
        video: videoConstraints,
        audio: false
      });
      this.isWebcamActive = true;

      this.webcamStream.getVideoTracks()[0].onended = () => this.stopWebcam();

      const camTrack = this.webcamStream.getVideoTracks()[0];
      for (const [userId, peer] of this.peers) {
        peer.connection.addTrack(camTrack, this.webcamStream);
        await this._renegotiate(userId, peer.connection);
      }

      this.socket.emit('webcam-started', { code: this.currentChannel });
      return true;
    } catch (err) {
      this.emit('error', err);
      this.isWebcamActive = false;
      this.webcamStream = null;
      return false;
    }
  }

  /**
   * Stop webcam.
   */
  async stopWebcam() {
    if (!this.isWebcamActive || !this.webcamStream) return;

    const tracks = this.webcamStream.getTracks();
    const renegotiations = [];
    for (const [userId, peer] of this.peers) {
      const senders = peer.connection.getSenders();
      tracks.forEach(track => {
        const sender = senders.find(s => s.track === track);
        if (sender) {
          try { peer.connection.removeTrack(sender); } catch {}
        }
      });
      renegotiations.push(this._renegotiate(userId, peer.connection).catch(() => {}));
    }

    try {
      await Promise.race([
        Promise.all(renegotiations),
        new Promise(resolve => setTimeout(resolve,