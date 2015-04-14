ogn-bootstrap
=============

This directory contains the files used for both image creation and web based installation for an OGN receiver.

Files
=====

bootstrap
---------

A basic shell script for running the installation on a new device.  It relies on the update script to install the correct version for the running hardware.  This will create the gpu nodes for RPI and setup a new 'flarm' user that the software will run as.

configure
---------

This script is the device end of the web based configuration found at http://ognconfig.onglide.com/

upgrade
-------

This script is designed to run as a crontab and check for software updates from the official OGN download servers

first-install
-------------

This is a system startup script that launches configure.  It is activated by bootstrap if selected and is active on binary images.  It is disabled once the installation successfully finishes

others
------
- httpi is a webserver used by configure http://www.floodgap.com/httpi/  it has been preconfigured to run on the binary image
- rtlsdr-flarm.conf is the default configuration file for the service
- rtlsdr-flarm is the system startup script that launches the flarm receiver.  By default it is not configured to start automatically until config has been completed.


Making your own image
=====================	
###Basic Installation

 0. use the bootstrap script to install the flarm tracker.  Choose OS upgrade & Web configuration but don't actually do the 
    web configuration
 1. change pi & wifi user passwords to defaults
     - useradd wifi
     - echo "wifi:wifi" | chpasswd
     - sudo apt-get install wicd-curses
     - sudo echo "/usr/bin/wicd-curses" >> /etc/shells
     - sudo chsh -s /usr/bin/wicd-curses wifi
     - test, and configure it to prefer LAN vs WiFi as it makes it much easier to use!
     - change the date on the server to something a while ago
      - sudo date -s 150101; echo "wifi:wifi" | chpasswd; echo "ogn:ogn" | chpasswd ; echo "pi:pi" | chpasswd;
      - on some devices set the root password to something strong and random AND disable ssh root logins altogether in /etc/ssh/sshd_config PermitRootLogin yes > PermitRootLogin no
      - (changing the dates ensures that passwords get regenerated properly )
      - Make sure ogn user or pi user has sudo full access (eg bananapi uses root by default so you need to help it out).  this is normally just a case of adding ogn to the sudo group.  You may also want to run visudo and allow sudoers to run commands without passwords like rpi does by default
 2. use the bootstrap script to install everything ready to go
     - curl http://ognconfig.onglide.com/files/v2.0/bootstrap -o bootstrap
     - chmod +x bootstrap
     - ./bootstrap
 3. sudo touch /etc/ssh/ssh_host_keyswrong 
     - rm /etc/sitetoken.txt
     - (ensures that ssh keys are regenerated on first install)
     - remove old configuration files

### Shrinking the image for distribution
 From here on down is optional if you want to shrink the image size:
 1. delete old logs files, ~/.history etc
 2. If on PI or other big image then remove x11 junk as you don't need it
    - sudo apt-get remove --auto-remove --purge libx11-.*
    - sudo apt-get autoremove
 3. locales and other stuff
    - sudo apt-get install localepurge deborphan     (during install you select which locales to keep! (raspi-config))
    - localepurge
 4. Clean up apt-get junk
    - apt-get autoremove
    - apt-get autoclean
    - apt-get clean
    - manually delete apt files in /var/cache/apt/
 5. remove gsm_scan output files
 6. size reduction, makes the image compress better: 
   - sudo dd if=/dev/zero of=t.1 bs=1M count=8 ; sudo dd if=/dev/zero of=t.2 bs=1M ; sudo rm t.1 t.2
   - history -c
 7. (optional) use something like gparted to resize the partition downwards
 8. Determine what to copy
   - fdisk /dev/disk2
      add start + size together to get number of sectors to copy.  
   -dd if=/xxx of=file bs=512 count=#
   - zip & bz2, md5sum and upload
