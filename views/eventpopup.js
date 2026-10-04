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

  /* id of the event currently shown in the modal, so a data refresh can update it in place */
  var openEventId = null;

  /* ---------- Helpers ---------- */
  function esc(s) {
    return String(s)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;')
      .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  }

  function close() {
    overlay.classList.remove('open');
    openEventId = null;
  }

  function attendeesHtml(list) {
    if (!list.length) return '<p class="em-meta"><em>No attendees yet.</em></p>';
    var h = '<div class="em-attendees"><h4>Attendees (' + list.length + ')</h4><ul>';
    list.forEach(function (a) {
      h += '<li>' + esc(a.name) + ' <em>(' + esc(a.type) + ')</em>';
      if (a.checkedIn) h += ' &#10003;';
      h += '</li>';
    });
    return h + '</ul></div>';
  }

  function declinedHtml(list) {
    if (!list.length) return '';
    var h = '<div class="em-declined"><h4>Declined (' + list.length + ')</h4><ul>';
    list.forEach(function (a) {
      h += '<li>' + esc(a.name) + ' <em>(' + esc(a.type) + ')</em></li>';
    });
    return h + '</ul></div>';
  }

  function countsHtml(d) {
    return '<p class="em-meta"><strong>Student count:</strong> ' + d.analysis.studentCount +
      ' (min <span class="' + (d.analysis.studentsSatisfied ? '' : 'low_count') + '">' + d.minStudents + '</span>' +
      (d.maxStudents > 0 ? ', max ' + d.maxStudents : '') + ')</p>' +
      '<p class="em-meta"><strong>Adult count:</strong> ' +
      '<span class="' + (d.analysis.mentorsSatisfied ? '' : 'low_count') + '">' + d.analysis.mentorCount + '</span>' +
      ' mentors, ' + d.analysis.parentCount + ' parents (min <span class="' +
      (d.analysis.adultsSatisfied ? '' : 'low_count') + '">' + d.minAdults + '</span>)</p>';
  }

  /* ---------- Open modal ---------- */
  function openModal(btn, silent) {
    var d = JSON.parse(btn.getAttribute('data-event-info'));
    var isAdmin = document.body.dataset.admin === 'true';
    var eid = encodeURIComponent(d.id);

    var isPast = btn.getAttribute('data-is-past') === 'true';
    var hidePeople = btn.getAttribute('data-hide-people') === 'true';
    var rsvpHtml = isPast
      ? ''
      : d.analysis.imGoing
        ? '<em class="em-declined-note">You are attending this event.</em>' +
          '<a class="em-withdraw" href="/rsvp?event_id=' + eid + '&response=none">Remove Response</a>' +
          '<a class="em-decline" href="/rsvp?event_id=' + eid + '&response=declined">Decline Instead</a>'
        : d.analysis.iDeclined
          ? '<em class="em-declined-note">You have declined this event.</em>' +
            '<a class="em-attend" href="/rsvp?event_id=' + eid + '&response=attending">Attend Instead</a>' +
            '<a class="em-withdraw" href="/rsvp?event_id=' + eid + '&response=none">Remove Response</a>'
          : (d.analysis.studentsMaxed
              ? '<a class="em-disabled" href="#">Full</a>'
              : '<a class="em-rsvp" href="/rsvp?event_id=' + eid + '&response=attending">Attend</a>') +
            '<a class="em-decline" href="/rsvp?event_id=' + eid + '&response=declined">Decline</a>';

    var adminHtml = isAdmin
      ? '<a class="em-edit"   href="/editEvent?id='   + eid + '">Edit</a>' +
        '<a class="em-delete" href="/deleteEvent?id=' + eid + '">Delete</a>'
      : '';

    modal.innerHTML =
      '<button class="em-close" aria-label="Close">&times;</button>' +
      '<h2 class="em-title">' + esc(d.title) +
        (d.prospectsAllowed ? ' <span class="prospect-badge" title="Prospects allowed">P</span>' : '') + '</h2>' +
      '<p class="em-meta"><strong>Type:</strong> '     + esc(d.type)     + '</p>' +
      (d.analysis.locName ? '<p class="em-meta"><strong>Location:</strong> ' + (d.analysis.locMapsUrl ? '<a href="' + esc(d.analysis.locMapsUrl) + '" target="_blank" rel="noopener">' + esc(d.analysis.locName) + '</a>' : esc(d.analysis.locName)) + '</p>' : '') +
      '<p class="em-meta"><strong>Start:</strong> '   + esc(d.start)    + '</p>' +
      '<p class="em-meta"><strong>End:</strong> '     + esc(d.end)      + '</p>' +
      countsHtml(d) +
      (hidePeople
        ? '<p class="em-meta"><em>' + d.analysis.attendeeCount + ' attending</em></p>'
        : attendeesHtml(d.attendees) + declinedHtml(d.declined)) +
      '<div class="em-actions">' + rsvpHtml + adminHtml + '</div>';

    modal.querySelector('.em-close').addEventListener('click', close);
    overlay.classList.add('open');
    openEventId = d.id;
    if (!silent) modal.querySelector('.em-close').focus();
  }

  /* ---------- Refresh modal contents in place after a data refresh ---------- */
  function refreshOpenModal() {
    if (!overlay.classList.contains('open') || openEventId == null) return;
    var btn = document.querySelector('.event-btn[data-event-id="' + CSS.escape(openEventId) + '"]');
    if (btn) {
      openModal(btn, true);
    } else {
      // the event is gone from the refreshed data (e.g. deleted)
      close();
    }
  }
  window.refreshOpenEventPopup = refreshOpenModal;

  /* ---------- Wire up events ---------- */
  overlay.addEventListener('click', function (e) {
    if (e.target === overlay) close();
  });

  document.addEventListener('keydown', function (e) {
    if (e.key === 'Escape') close();
  });

  document.addEventListener('click', function (e) {
    var btn = e.target.closest && e.target.closest('.event-btn');
    if (btn) { e.preventDefault(); openModal(btn); return; }

    /* ---------- Show past events (delegated: content is replaced by autorefresh.js) ---------- */
    var showPastBtn = e.target.closest && e.target.closest('#show-past');
    if (showPastBtn) {
      document.querySelectorAll('.hidden_data').forEach(function (el) {
        el.classList.add('revealed');
      });
      showPastBtn.style.display = 'none';
    }
  });
});
