document.addEventListener('DOMContentLoaded', function () {
  'use strict';

  var container = document.getElementById('calendar-refresh');
  if (!container) return;

  var url = container.dataset.refreshUrl;
  var banner = document.getElementById('session-expired-banner');

  function refresh() {
    fetch(url + location.search, { credentials: 'same-origin' })
      .then(function (res) {
        if (res.status === 401) {
          if (banner) banner.hidden = false;
          return Promise.reject(401);
        }
        return res.ok ? res.text() : Promise.reject(res.status);
      })
      .then(function (html) {
        container.innerHTML = html;
        if (window.refreshOpenEventPopup) window.refreshOpenEventPopup();
      })
      .catch(function () { /* skip this refresh; the next interval will retry */ });
  }

  setInterval(refresh, 60000);
});
