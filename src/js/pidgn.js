/**
 * pidgn.js — Client-side library for the Pidgn web framework.
 *
 * Provides WebSocket with auto-reconnect, fetch wrapper, and form submission helper.
 */
const Pidgn = {
  /**
   * Connect to a WebSocket endpoint with auto-reconnect and exponential backoff.
   *
   * @param {string} url - WebSocket URL (e.g., "ws://localhost:9000/ws/echo")
   * @param {object} opts - Options
   * @param {number} opts.maxRetries - Max reconnect attempts (default: 10)
   * @param {number} opts.baseDelay - Base delay in ms for backoff (default: 1000)
   * @param {number} opts.maxDelay - Max delay in ms (default: 30000)
   * @returns {{ send, on, close, readyState }}
   */
  connect(url, opts = {}) {
    const maxRetries = opts.maxRetries ?? 10;
    const baseDelay = opts.baseDelay ?? 1000;
    const maxDelay = opts.maxDelay ?? 30000;

    const listeners = { open: [], message: [], close: [], error: [] };
    let ws = null;
    let retries = 0;
    let intentionalClose = false;

    function emit(event, data) {
      (listeners[event] || []).forEach(fn => fn(data));
    }

    function createWs() {
      ws = new WebSocket(url);

      ws.onopen = () => {
        retries = 0;
        emit("open", ws);
      };

      ws.onmessage = (e) => {
        emit("message", e.data);
      };

      ws.onclose = (e) => {
        emit("close", { code: e.code, reason: e.reason });
        if (!intentionalClose && retries < maxRetries) {
          const delay = Math.min(baseDelay * Math.pow(2, retries), maxDelay);
          retries++;
          setTimeout(createWs, delay);
        }
      };

      ws.onerror = (e) => {
        emit("error", e);
      };
    }

    createWs();

    return {
      send(data) { if (ws && ws.readyState === WebSocket.OPEN) ws.send(data); },
      on(event, fn) { if (listeners[event]) listeners[event].push(fn); },
      close(code, reason) { intentionalClose = true; if (ws) ws.close(code || 1000, reason || ""); },
      get readyState() { return ws ? ws.readyState : WebSocket.CLOSED; },
    };
  },

  /**
   * Fetch wrapper with auto CSRF token from <meta name="csrf-token">.
   *
   * @param {string} url - Request URL
   * @param {object} opts - fetch() options, plus `json` shorthand for JSON body
   * @returns {Promise<Response>}
   */
  async fetch(url, opts = {}) {
    const headers = new Headers(opts.headers || {});

    // Auto-attach CSRF token for non-GET requests
    const method = (opts.method || "GET").toUpperCase();
    if (method !== "GET" && method !== "HEAD") {
      const meta = document.querySelector('meta[name="csrf-token"]');
      if (meta) {
        headers.set("X-CSRF-Token", meta.getAttribute("content"));
      }
    }

    // JSON shorthand
    if (opts.json !== undefined) {
      headers.set("Content-Type", "application/json");
      opts.body = JSON.stringify(opts.json);
      delete opts.json;
    }

    opts.headers = headers;
    return fetch(url, opts);
  },

  /**
   * Submit a form via AJAX (FormData), with auto CSRF.
   *
   * @param {HTMLFormElement|string} form - Form element or CSS selector
   * @param {object} opts - Additional fetch options
   * @returns {Promise<Response>}
   */
  async formSubmit(form, opts = {}) {
    const el = typeof form === "string" ? document.querySelector(form) : form;
    if (!el) throw new Error("Form not found");

    const method = (el.method || "POST").toUpperCase();
    const action = el.action || window.location.href;
    const body = new FormData(el);

    return Pidgn.fetch(action, { method, body, ...opts });
  },

  /**
   * Create a Phoenix-style channel socket connection.
   *
   * @param {string} url - WebSocket URL (e.g., "ws://localhost:9000/socket")
   * @param {object} opts - Options
   * @param {number} opts.heartbeatInterval - Heartbeat interval in ms (default: 30000)
   * @param {number} opts.maxRetries - Max reconnect attempts (default: 10)
   * @param {number} opts.baseDelay - Base delay in ms for backoff (default: 1000)
   * @param {number} opts.maxDelay - Max delay in ms (default: 30000)
   * @returns {{ channel, disconnect, connected }}
   */
  socket(url, opts = {}) {
    const heartbeatInterval = opts.heartbeatInterval ?? 30000;
    const maxRetries = opts.maxRetries ?? 10;
    const baseDelay = opts.baseDelay ?? 1000;
    const maxDelay = opts.maxDelay ?? 30000;

    let ws = null;
    let retries = 0;
    let intentionalClose = false;
    let refCounter = 0;
    let heartbeatTimer = null;
    const pendingReplies = {};
    const channels = {};
    let sendQueue = [];

    function nextRef() {
      refCounter++;
      return String(refCounter);
    }

    function sendMsg(topic, event, payload, ref) {
      var raw = JSON.stringify({ topic: topic, event: event, payload: payload || {}, ref: ref || null });
      if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(raw);
      } else {
        sendQueue.push(raw);
      }
    }

    function flushQueue() {
      while (sendQueue.length > 0 && ws && ws.readyState === WebSocket.OPEN) {
        ws.send(sendQueue.shift());
      }
    }

    function startHeartbeat() {
      stopHeartbeat();
      heartbeatTimer = setInterval(function() {
        sendMsg("phoenix", "heartbeat", {}, nextRef());
      }, heartbeatInterval);
    }

    function stopHeartbeat() {
      if (heartbeatTimer) {
        clearInterval(heartbeatTimer);
        heartbeatTimer = null;
      }
    }

    function handleMessage(data) {
      var msg;
      try { msg = JSON.parse(data); } catch(e) { return; }

      var topic = msg.topic;
      var event = msg.event;
      var payload = msg.payload;
      var ref = msg.ref;

      // Handle reply — resolve/reject pending promises
      if (event === "phx_reply" && ref && pendingReplies[ref]) {
        var p = pendingReplies[ref];
        delete pendingReplies[ref];
        if (payload && payload.status === "ok") {
          p.resolve(payload.response || {});
        } else {
          p.reject(payload);
        }
        return;
      }

      // Route to channel listeners
      if (channels[topic]) {
        var ch = channels[topic];
        if (ch.listeners[event]) {
          ch.listeners[event].forEach(function(fn) { fn(payload); });
        }
      }
    }

    function createWs() {
      ws = new WebSocket(url);

      ws.onopen = function() {
        retries = 0;
        startHeartbeat();
        // Flush any queued messages (e.g. join sent before connection opened)
        flushQueue();
        // Rejoin channels that were previously joined (reconnect case)
        Object.keys(channels).forEach(function(topic) {
          var ch = channels[topic];
          if (ch.joined) {
            ch.joined = false;
            ch.join();
          }
        });
      };

      ws.onmessage = function(e) {
        handleMessage(e.data);
      };

      ws.onclose = function() {
        stopHeartbeat();
        if (!intentionalClose && retries < maxRetries) {
          var delay = Math.min(baseDelay * Math.pow(2, retries), maxDelay);
          retries++;
          setTimeout(createWs, delay);
        }
      };

      ws.onerror = function() {};
    }

    createWs();

    return {
      /**
       * Create a channel for the given topic.
       * @param {string} topic - Topic name (e.g., "room:lobby")
       * @param {object} params - Join params
       * @returns {{ join, leave, push, on, off }}
       */
      channel(topic, params) {
        var ch = {
          topic: topic,
          params: params || {},
          joined: false,
          listeners: {},

          join() {
            return new Promise(function(resolve, reject) {
              var ref = nextRef();
              pendingReplies[ref] = { resolve: function(r) { ch.joined = true; resolve(r); }, reject: reject };
              sendMsg(topic, "phx_join", ch.params, ref);
            });
          },

          leave() {
            return new Promise(function(resolve, reject) {
              var ref = nextRef();
              pendingReplies[ref] = { resolve: function(r) { ch.joined = false; resolve(r); }, reject: reject };
              sendMsg(topic, "phx_leave", {}, ref);
            });
          },

          push(event, payload) {
            return new Promise(function(resolve, reject) {
              var ref = nextRef();
              pendingReplies[ref] = { resolve: resolve, reject: reject };
              sendMsg(topic, event, payload || {}, ref);
            });
          },

          on(event, callback) {
            if (!ch.listeners[event]) ch.listeners[event] = [];
            ch.listeners[event].push(callback);
            return ch;
          },

          off(event) {
            delete ch.listeners[event];
            return ch;
          }
        };

        channels[topic] = ch;
        return ch;
      },

      disconnect() {
        intentionalClose = true;
        stopHeartbeat();
        if (ws) ws.close(1000, "");
      },

      get connected() {
        return ws && ws.readyState === WebSocket.OPEN;
      }
    };
  },
};

if (typeof module !== "undefined" && module.exports) {
  module.exports = Pidgn;
}
