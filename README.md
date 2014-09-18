rsyncsync
=========

**Note**: this is a proof of concept.

Synchronise multiple locations, 2-way, with backups, using only rsync
and basic POSIX tools.

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

Soon: support for encrypted remotes using encfs, and partial backups for
high-frequency sync of file sub-sets.


## usage

For each source and backup you want, do:

```bash
rsyncsync SOURCE-DIR [HOST:]BACKUP-PATH
```

Synchronisation occurs in a direction based on whether the local files
have changed relative to the previous invocation, using only the local
clock and an opaque stamp signalling that the remote has changed and
needs pulling.



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



