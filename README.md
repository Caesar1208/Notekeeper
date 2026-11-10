# Notekeeper

Notes and tasks for **WoW Forever**, in the classic interface's look, that pop up when you need them.

- **Notes with tasks.** Each note has a title, text and a checklist of tasks. Ticking the last task
  completes the note.
- **Conditions.** A note, or any single task in it, can pop up by itself: entering a zone or city,
  entering a dungeon, reaching a level, logging in, opening a vendor, bank, mailbox, auction house,
  trainer or flight master, or targeting someone. Pick one with **Add**, or type tags like
  `zone:Stormwind, vendor, level:20`.
- **Reminders.** A classic dialog with Done and Later. A task's reminder shows just that task.
  Optional sound, per note or as a default.
- **On screen.** Show notes and their tasks like the quest tracker and tick them off right there.
- **Auto-archive.** Ticked notes move to the Archive at once, after a minute, an hour, a day, a week,
  or never; untouched notes can be archived too.

Open it with `/nk`, the minimap button, the AddOns menu or a keybinding.
`/nk add Buy arrows @vendor` makes a quick note from chat.

## Condition tags

| Tag | Pops up when |
|---|---|
| `zone:Stormwind` | entering a zone or area |
| `city` | entering any city or inn |
| `dungeon` / `dungeon:Deadmines` | entering any dungeon, or that one |
| `level:20` | reaching level 20 |
| `login` | logging in |
| `vendor` `bank` `mail` `auction` `trainer` `flight` | opening one of those |
| `target:Hogger` | targeting someone |

Separate tags with commas; any one of them is enough. Case doesn't matter and part of a name is enough.

## Install

Copy this folder into `World of Warcraft/_forever_/Interface/AddOns/` (named `Notekeeper`).
