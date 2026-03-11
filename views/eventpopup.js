document.addEventListener('DOMContentLoaded', function () {
  'use strict';

  /* ---------- Build modal DOM ---------- */
  var overlay = document.createElement('div');
  overlay.id = 'event-modal-overlay';
  overlay.setAttribute('role', 'dialog');
  overlay.setAttribute('aria-modal', 'true');
  overlay.setAttribute('aria-label', 'Event details');

  var modal = document.createElement('div');
  modal.id = 'event-modal';
  overlay.appendChild(modal);
  document.body.appendChild(overlay);

  /* ---------- Helpers ---------- */
  function esc(s) {
    return String(s)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;')
      .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  }

  function close() {
    overlay.classList.remove('open');
  }

  function attendeesHtml(json) {
    if (!json) return '';
    var list;
    try { list = JSON.parse(json); } catch (e) { return ''; }
    if (!list.length) return '<p class="em-meta"><em>No attendees yet.</em></p>';
    var h = '<div class="em-attendees"><h4>Attendees (' + list.length + ')</h4><ul>';
    list.forEach(function (a) {
      h += '<li>' + esc(a.name) + ' <em>(' + esc(a.type) + ')</em>';
      if (a.checkedIn) h += ' &#10003;';
      h += '</li>';
    });
    return h + '</ul></div>';
  }

  /* ---------- Open modal ---------- */
  function openModal(btn) {
    var d = btn.dataset;
    var isAdmin = document.body.dataset.admin === 'true';
    var imGoing = d.imGoing === 'true';
    var eid = encodeURIComponent(d.eventId);

    var rsvpHtml = imGoing
      ? '<a class="em-cancel-rsvp" href="/rsvp?event_id=' + eid + '&attending=false">Cancel RSVP</a>'
      : '<a class="em-rsvp"        href="/rsvp?event_id=' + eid + '&attending=true">RSVP</a>';

    var adminHtml = isAdmin
      ? '<a class="em-edit" href="/editEvent?event_id=' + eid + '">Edit Event</a>'
      : '';

    modal.innerHTML =
      '<button class="em-close" aria-label="Close">&times;</button>' +
      '<h2 class="em-title">' + esc(d.title) + '</h2>' +
      '<p class="em-meta"><strong>Type:</strong> '     + esc(d.type)     + '</p>' +
      (d.location ? '<p class="em-meta"><strong>Location:</strong> ' + esc(d.location) + '</p>' : '') +
      '<p class="em-meta"><strong>Start:</strong> '   + esc(d.start)    + '</p>' +
      '<p class="em-meta"><strong>End:</strong> '     + esc(d.end)      + '</p>' +
      attendeesHtml(d.attendees) +
      '<div class="em-actions">' + rsvpHtml + adminHtml + '</div>';

    modal.querySelector('.em-close').addEventListener('click', close);
    overlay.classList.add('open');
    modal.querySelector('.em-close').focus();
  }

  /* ---------- Wire up events ---------- */
  overlay.addEventListener('click', function (e) {
    if (e.target === overlay) close();
  });

  document.addEventListener('keydown', function (e) {
    if (e.key === 'Escape') close();
  });

  document.addEventListener('click', function (e) {
    var btn = e.target.closest && e.target.closest('.event-btn');
    if (btn) { e.preventDefault(); openModal(btn); }
  });
});
