[% cwd = whole.cwd %]

<h2>Edit request</h2>
<form method="POST" action="[% here %]" id="edit_form">
  <fieldset class="rows">
    <legend>Edit metadata</legend>
    <input name="illrequest_id" value="[% whole.value.other.illrequest_id %]" type="hidden" />
    <input name="stage" id="stage" value="form" type="hidden"/>
    <input name="method" id="method" value="edititem" type="hidden"/>
    <input name="backend" id="backend" value="ReprintsDesk" type="hidden"/>
    <ol>
      [% FOREACH field IN whole.field_map %]
      [% key = field.key %]
      [% IF !field.exclude %]
      <li id="reprints_desk_field_[% key %]">
        <label class="reprints_desk_label" id="[% key %]_label" for="[% key %]">[% field.label | html %]</label>
        <input type="text" name="[% key %]" id="[% key %]" value="[% whole.value.other.$key %]" />
        [% IF field.help %]
        ([% field.help %])
        [% END %]
      </li>
      [% END %]
      [% END %]
    </ol>
  </fieldset>
  <fieldset class="action">
    <input id="update_submit" type="submit" value="Update"/>
    <a class="cancel" href="/cgi-bin/koha/ill/ill-requests.pl">Cancel</a>
  </fieldset>
</form>