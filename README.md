# mondieu

mondieu - portable alternative for freebsd-update.

mondieu is a simple replacement for freebsd-update. It allows you to just upgrade to whatever version of a FreeBSD release you want, as long as you have the releases' tarballs.

Just like freebsd-update it will scan your current filesystem and build a list of files that differ from the release. After confirming the list, it will be installed and you will get the chance to manually merge your config files. Unlike freebsd-update, this merging can't be done automatically lacking a common reference point for both releases.

## Usage
mondieu is pretty easy to use and will take a couple of minutes to completely upgrade your system.

Issueing ```mondieu 10.1-RELEASE``` will download tarballs for 10.1-RELEASE from FreeBSD's primary source and install the files to your current system.

Optionally, these parameters can be used to customize mondieu's behaviour:

- **-a** architecture (default: current architecture)
- **-d** alternative chroot (default: /)
- **-h** show you these settings
- **-p** parts of FreeBSD that are considered (default: kernel,base)
- **-w** don't manually merge these files but overwrite with new version
- **-x** ignore files for manual merge
- **-X** ignore files for manual merge when matching this pattern
- **-u** URL tarballs are fetched from (default: ftp://ftp.freebsd.org/pub/FreeBSD/releases/$architecture/$release/)

**Note**: both **-w** and **-x** expect a single argument, so use quotes to define more files

### beadm
Combine mondieu with [beadm](https://github.com/vermaden/beadm) to create snapshots of your current filesystem before upgrading. When everything went smoothly, activate the snapshot as you current root filesystem and boot into it or otherwise revert:

```
beadm create myupgrade
beadm mount myupgrade /mnt
mondieu -d /mnt 10.1-RELEASE
beadm umount myupgrade
beadm activate myupgrade
reboot
```

**Note**: this will only work when your root filesystem has been prepared for this. Read beadm's [HOWTO](https://github.com/vermaden/beadm/blob/master/HOWTO.htm) for instructions how you should prepare your filesystem to benefit from beadm.


## ToDo
- check signature of downloaded tarballs
- support for tarballs on the filesystem instead of remote location
- detection of which parts (eg. kernel, base and doc) should be installed

## Known issues
- merging configuration files cannot be done automatically since there is no common reference point for your current release and the one you're upgrading to.
- same goes for deleting deprecated files, there is currently no way of knowing which files can be deleted.

## Contributing

Please help me make this tool better. Send feedback or even a pull request and help improve where you can.
