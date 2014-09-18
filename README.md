rsyncsync
=========

Dr-pb-x-alike using only rsync and an SSH server (and some basic POSIX
tools.)

Synchronise multiple locations, with backups, using only rsync.

Attempts to ensure that data are never overwritten and always backed up.
Can use multiple backup locations and sync multiple working directories.

Backups are kept on the server using rsnapshot-style hard links.
Potential conflicts are detected locally and files copied to a separate
directory.

Soon: adding support for encrypted remotes using encfs, and partial
backups for high-frequency sync of file sub-sets.


## usage

For each source and backup you want, do:

```bash
rsyncsync SOURCE [HOST:]PATH
```



## requirements

(Haven't checked minimum versions)


### backup (server) requirements

* ssh-server (if remote)
* rsync
* coreutils
* sh
* filesystem with hard link support, e.g. ext2


## client requirements

* rsync
* coreutils
* findutils
* ssh (for remote backups)




