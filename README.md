rsyncsync
=========

Synchronise multiple locations, 2-way, with backups, using only rsync
and basic POSIX tools.  Optionally encrypt remotes using encfs
(encryption performed locally before sending to remote.)

**Note**: this assumes a mostly single-user scenario, where files will
generally only be modified in one place at a time.  There is no fancy
merging, only backing up of files that *might* have changed, to save
your bacon if you lose synchronisation for a time.

This attempts to ensure that data are never overwritten and always
backed up.  Can use multiple backup locations and sync multiple working
directories.  (Seems to work well in my testing but no theoretical proof
for N:M consistency, YMMV, etc.)

Backups are kept using rsnapshot-style hard links.  Potential conflicts
are detected locally and files copied to a separate local directory, and
then backed up to the remote.



## behaviour

  local state   | backup state  | action
 ---------------|---------------|----------------------
  empty/missing | empty/missing | init local & push
  tracked       | empty/missing | push (init remote)
  empty         | tracked       | pull (restore)
  missing       | tracked       | abort
  unchanged     | unchanged     | do nothing
  changed       | unchanged     | push
  unchanged     | changed       | pull and overwrite
  changed       | changed       | pull+backup then push

where:

    empty: directory empty or non-existent
    missing: directory not empty but missing state data
    tracked: directory exists with state data

Local changed status is determined by comparing modified times to the
time of the most recent pull or push (so only the local clock is used).

Remote changed status is determined by comparing an opaque stamp that
changes whenever a remote is updated.  Remotes are only changed by
pushing from another (synchronised) local.  Multiple remotes can be
used, and the state of each is kept distinct.

Note that files are never overwritten when pushing so it is safe to push
to a remote that is missing state data.


## usage

For each source and backup you want, do:

```bash
rsyncsync SOURCE-DIR [HOST:]BACKUP-PATH
```


## requirements

### backup requirements

backup can be local or remote

* ssh-server (if remote)
* rsync
* coreutils
* sh
* filesystem with hard link support, e.g. ext2


### client requirements

* bash
* rsync
* coreutils
* findutils
* ssh for remote backup, public-key auth recommended


