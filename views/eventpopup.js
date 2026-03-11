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

  /* ---------- Inject styles ---------- */
  var style = document.createElement('style');
  style.textContent = [
    '#event-modal-overlay {',
    '  display: none; position: fixed; inset: 0;',
    '  background: rgba(0,0,0,.5); z-index: 1000;',
    '  align-items: center; justify-content: center;',
    '}',
    '#event-modal-overlay.open { display: flex; }',
    '#event-modal {',
    '  background: #fff; border-radius: 6px; padding: 1.5rem;',
    '  max-width: 480px; width: 90%; max-height: 80vh; overflow-y: auto;',
    '  position: relative; box-shadow: 0 4px 24px rgba(0,0,0,.3);',
    '}',
    '.em-close {',
    '  position: absolute; top: .5rem; right: .75rem;',
    '  background: none; border: none; font-size: 1.3rem; cursor: pointer;',
    '}',
    '.em-title { margin: 0 2rem .5rem 0; font-size: 1.2rem; }',
    '.em-meta { margin: .2rem 0; font-size: .9rem; }',
    '.em-attendees { margin-top: .75rem; }',
    '.em-attendees h4 { margin: 0 0 .25rem; }',
    '.em-attendees ul { margin: 0; padding-left: 1.25rem; font-size: .9rem; }',
    '.em-actions { margin-top: 1rem; display: flex; gap: .5rem; flex-wrap: wrap; }',
    '.em-actions a {',
    '  padding: .4rem .9rem; border-radius: 4px;',
    '  text-decoration: none; font-size: .9rem; display: inline-block;',
    '}',
    '.em-rsvp        { background: #3a7; color: #fff; }',
    '.em-cancel-rsvp { background: #c55; color: #fff; }',
    '.em-edit        { background: #57b; color: #fff; }',
  ].join('\n');
  document.head.appendChild(style);

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
    console.log(d);
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
