document.addEventListener('DOMContentLoaded', function () {
  'use strict';

  var container = document.getElementById('calendar-refresh');
  if (!container) return;

  var url = container.dataset.refreshUrl;

  function refresh() {
    fetch(url + location.search, { credentials: 'same-origin' })
      .then(function (res) { return res.ok ? res.text() : Promise.reject(res.status); })
      .then(function (html) {
        container.innerHTML = html;
        if (window.refreshOpenEventPopup) window.refreshOpenEventPopup();
      })
      .catch(function () { /* skip this refresh; the next interval will retry */ });
  }

  setInterval(refresh, 60000);
});
