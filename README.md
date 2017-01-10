ogn-bootstrap
=============

This directory contains the files used for both image creation and web based installation for an OGN receiver.

Files
=====

bootstrap
---------

A basic shell script for running the installation on a new device.  It relies on the update script to install the correct version for the running hardware.  This will create the gpu nodes for RPI and setup a new 'ogn' user that the software will run as.

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
- rtlsdr-ogn.conf is the default configuration file for the service
- rtlsdr-ogn is the system startup script that launches the ogn receiver.  By default it is not configured to start automatically until config has been completed.


Making your own image
=====================	
    ###Basic Install
    0. use the bootstrap script to install the ogn tracker.  Choose OS upgrade & Web configuration but don't actually do the 
    web configuration
 1. change pi & wifi user passwords to defaults
     - useradd wifi
     - echo "wifi:wifi" | chpasswd
     - sudo apt-get install wicd-curses
     - sudo echo "/usr/bin/wicd-curses" >> /etc/shells
     - sudo chsh -s /usr/bin/wicd-curses wifi
     - sudo vipw & set shell for wifi to /usr/bin/wicd-curses
     - test, and configure it to prefer LAN vs WiFi as it makes it much easier to use!
     - update the password dates use (passwd -S pi to get them) in the password change check grep in the configure script
 2. sudo touch /etc/ssh/ssh_host_keyswrong 
     - rm /etc/sitetoken.txt
     - (ensures that ssh keys are regenerated on first install)
     - remove old configuration files
 3. fresh installs only: use the bootstrap script to install everything ready to go
     - curl http://ognconfig.onglide.com/files/v1.4/bootstrap -o bootstrap
     - chmod +x bootstrap
     - ./bootstrap
 4. copy Example.conf to /home/ogn/rtlsdr-ogn.conf
 5. remove gsm_scan output files
 6. enable first-install and disable rtlsdr-ogn
    - curl http://ognconfig.onglide.com/files/v1.4/first-install -o /etc/init.d/first-install
    - /usr/bin/sudo /usr/sbin/update-rc.d first-install defaults
    - /usr/bin/sudo /usr/sbin/update-rc.d rtlsdr-ogn remove

### Shrinking the image for distribution
 From here on down is optional if you want to shrink the image size:
 1. delete old logs files, ~/.history etc
	rm /home/pi/.bash_history /root/.bash_history /home/ogn/.bash_history
	echo > /var/log/...
	    
 2. If on PI or other big image then remove x11 junk as you don't need it
    sudo apt-get remove --auto-remove --purge libx11-.*
    sudo apt-get autoremove
 3. locales and other stuff
    sudo apt-get install localepurge deborphan     (during install you select which locales to keep! (raspi-config))
	localepurge
	apt-get remove `deborphan`
    Clean up apt-get junk
    - apt-get autoremove
    - apt-get autoclean
    - apt-get clean
    - manually delete apt files in /var/
 4. if you've done much stuff then (makes it compress better)
   - sudo dd if=/dev/zero of=t.1 bs=1M count=8 ; sudo dd if=/dev/zero of=t.2 bs=1M ; sudo rm t.1 t.2
 5. (optional) use something like gpart to resize the partition downwards
 11. fdisk /dev/disk2
      add start + size together to get number of sectors to copy.  dd if=/xxx of=file bs=512 count=#
