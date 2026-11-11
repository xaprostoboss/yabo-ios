import Foundation

/// WKWebView 注入脚本：与 Android 端 YaboBridge + 网络 hook 等价
enum JSPayload {

    /// 把原生方法挂到 window.YaboBridge，转发给 WKScriptMessageHandler("yabo")
    static let bridgeShim = #"""
    (function(){
      if (window.YaboBridge && window.YaboBridge.__ios) return;
      window.YaboBridge = {
        __ios: true,
        onData: function(k, u){
          try {
            if (!u) return;
            webkit.messageHandlers.yabo.postMessage({op:'data', kind:String(k||'video'), url:String(u)});
          } catch(e){}
        },
        onDetail: function(t){
          try { webkit.messageHandlers.yabo.postMessage({op:'detail', text:String(t||'').substring(0,400000)}); } catch(e){}
        },
        onLog: function(s){
          try { webkit.messageHandlers.yabo.postMessage({op:'log', text:String(s||'')}); } catch(e){}
        }
      };
    })();
    """#

    /// hook fetch / XHR，把 media URL 与 aweme_detail 报文回传
    static let networkHook = #"""
    (function(){
      if (window.__yaboHooked) return;
      window.__yaboHooked = 1;

      function push(kind, u){
        try {
          if (!u) return;
          u = String(u).replace(/\\u002F/g, '/').replace(/\\\//g, '/');
          if (u.indexOf('http') !== 0) return;
          if (window.YaboBridge) window.YaboBridge.onData(kind, u);
        } catch(e){}
      }

      function scan(txt){
        if (!txt) return;
        try {
          if (txt.indexOf('"aweme_detail"') >= 0 && window.YaboBridge) {
            window.YaboBridge.onDetail(String(txt).substring(0, Math.min(String(txt).length, 400000)));
          }
          var m;
          var re1 = /"play_addr"\s*:\s*\{[\s\S]{0,800}?"url_list"\s*:\s*\[\s*"([^"]+)"/g;
          while ((m = re1.exec(txt))) push('video', m[1]);

          var re2 = /"url_list"\s*:\s*\[\s*"(https?:[^"]*(?:douyinpic|byteimg|xhscdn|kwaicdn|kscdn|yximgs|kwimgs|ndcimgs)[^"]*)"/g;
          while ((m = re2.exec(txt))) push('image', m[1]);

          var re3 = /(https?:\/\/[^"'\\\s]*(?:douyinvod|zjcdn|snssdk|xhscdn|kwaicdn|kscdn|yximgs)[^"'\\\s]*)/g;
          while ((m = re3.exec(txt))) push('video', m[1]);
        } catch(e){}
      }

      var of = window.fetch;
      if (of) {
        window.fetch = function(){
          var p = of.apply(this, arguments);
          try {
            p.then(function(r){
              try { r.clone().text().then(scan); } catch(e){}
            });
          } catch(e){}
          return p;
        };
      }

      var XO = XMLHttpRequest.prototype.open;
      var XS = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function(m, u){ this.__u = u; return XO.apply(this, arguments); };
      XMLHttpRequest.prototype.send = function(){
        var s = this;
        this.addEventListener('load', function(){
          try { scan(s.responseText || ''); } catch(e){}
        });
        return XS.apply(this, arguments);
      };

      try { if (window.YaboBridge) window.YaboBridge.onLog('hook-installed'); } catch(e){}
    })();
    """#

    /// 页面加载后补扫：DOM 里的 video/img、_ROUTER_DATA、__INITIAL_STATE__
    static let domScanner = #"""
    (function(){
      try { if (window.YaboBridge) window.YaboBridge.onLog('page=' + location.href); } catch(e){}
      var id = window.__yaboId || '';
      try {
        var rd = window._ROUTER_DATA;
        if (rd) {
          var rs = JSON.stringify(rd);
          if (rs && window.YaboBridge) window.YaboBridge.onDetail(rs);
        }
      } catch(e){}
      try {
        var g = window.__INITIAL_STATE__ || window.__APOLLO_STATE__ || window.__INIT_DATA__;
        if (g) {
          var gt = JSON.stringify(g);
          var re = /(https?:[^"\\]*(?:xhscdn|yximgs|kwaicdn|kscdn|kwimgs|ndcimgs)[^"\\]*)/g, mm;
          while ((mm = re.exec(gt))) {
            try {
              window.YaboBridge.onData(/mp4|sns-video|\/upic\//.test(mm[1]) ? 'video' : 'image', mm[1]);
            } catch(e){}
          }
        }
      } catch(e){}
      try {
        var vs = document.querySelectorAll('video');
        for (var i = 0; i < vs.length; i++) {
          var s0 = vs[i].src || vs[i].currentSrc;
          if (s0 && s0.indexOf('http') === 0 && window.YaboBridge) window.YaboBridge.onData('video', s0);
        }
        var is = document.querySelectorAll('img');
        for (var k = 0; k < is.length; k++) {
          var u = is[k].src;
          if (u && /douyinpic|byteimg|zjcdn|xhscdn|kwaicdn|kscdn|yximgs/.test(u) && window.YaboBridge) {
            window.YaboBridge.onData('image', u);
          }
        }
      } catch(e){}
    })();
    """#
}
