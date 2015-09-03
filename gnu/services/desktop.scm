;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2014, 2015 Ludovic Courtès <ludo@gnu.org>
;;; Copyright © 2015 Andy Wingo <wingo@igalia.com>
;;; Copyright © 2015 Mark H Weaver <mhw@netris.org>
;;;
;;; This file is part of GNU Guix.
;;;
;;; GNU Guix is free software; you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation; either version 3 of the License, or (at
;;; your option) any later version.
;;;
;;; GNU Guix is distributed in the hope that it will be useful, but
;;; WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;; GNU General Public License for more details.
;;;
;;; You should have received a copy of the GNU General Public License
;;; along with GNU Guix.  If not, see <http://www.gnu.org/licenses/>.

(define-module (gnu services desktop)
  #:use-module (gnu services)
  #:use-module (gnu services base)
  #:use-module (gnu services avahi)
  #:use-module (gnu services xorg)
  #:use-module (gnu services networking)
  #:use-module (gnu system shadow)
  #:use-module (gnu system linux) ; unix-pam-service
  #:use-module (gnu packages glib)
  #:use-module (gnu packages admin)
  #:use-module (gnu packages freedesktop)
  #:use-module (gnu packages gnome)
  #:use-module (gnu packages avahi)
  #:use-module (gnu packages wicd)
  #:use-module (gnu packages polkit)
  #:use-module ((gnu packages linux)
                #:select (lvm2 fuse alsa-utils crda))
  #:use-module (guix monads)
  #:use-module (guix records)
  #:use-module (guix store)
  #:use-module (guix gexp)
  #:use-module (ice-9 match)
  #:export (dbus-service
            upower-service
            colord-service
            geoclue-application
            %standard-geoclue-applications
            geoclue-service
            polkit-service
            elogind-configuration
            elogind-service
            %desktop-services))

;;; Commentary:
;;;
;;; This module contains service definitions for a "desktop" environment.
;;;
;;; Code:


;;;
;;; Helpers.
;;;

(define (bool value)
  (if value "true\n" "false\n"))


;;;
;;; D-Bus.
;;;

(define (dbus-configuration-directory dbus services)
  "Return a configuration directory for @var{dbus} that includes the
@code{etc/dbus-1/system.d} directories of each package listed in
@var{services}."
  (define build
    #~(begin
        (use-modules (sxml simple)
                     (srfi srfi-1))

        (define (services->sxml services)
          ;; Return the SXML 'includedir' clauses for DIRS.
          `(busconfig
            ,@(append-map (lambda (dir)
                            `((includedir
                               ,(string-append dir "/etc/dbus-1/system.d"))
                              (servicedir         ;for '.service' files
                               ,(string-append dir "/share/dbus-1/services"))))
                          services)))

        (mkdir #$output)
        (copy-file (string-append #$dbus "/etc/dbus-1/system.conf")
                   (string-append #$output "/system.conf"))

        ;; The default 'system.conf' has an <includedir> clause for
        ;; 'system.d', so create it.
        (mkdir (string-append #$output "/system.d"))

        ;; 'system-local.conf' is automatically included by the default
        ;; 'system.conf', so this is where we stuff our own things.
        (call-with-output-file (string-append #$output "/system-local.conf")
          (lambda (port)
            (sxml->xml (services->sxml (list #$@services))
                       port)))))

  (gexp->derivation "dbus-configuration" build))

(define* (dbus-service services #:key (dbus dbus))
  "Return a service that runs the \"system bus\", using @var{dbus}, with
support for @var{services}.

@uref{http://dbus.freedesktop.org/, D-Bus} is an inter-process communication
facility.  Its system bus is used to allow system services to communicate and
be notified of system-wide events.

@var{services} must be a list of packages that provide an
@file{etc/dbus-1/system.d} directory containing additional D-Bus configuration
and policy files.  For example, to allow avahi-daemon to use the system bus,
@var{services} must be equal to @code{(list avahi)}."
  (mlet %store-monad ((conf (dbus-configuration-directory dbus services)))
    (return
     (service
      (documentation "Run the D-Bus system daemon.")
      (provision '(dbus-system))
      (requirement '(user-processes))
      (start #~(make-forkexec-constructor
                (list (string-append #$dbus "/bin/dbus-daemon")
                      "--nofork"
                      (string-append "--config-file=" #$conf "/system.conf"))))
      (stop #~(make-kill-destructor))
      (user-groups (list (user-group
                          (name "messagebus")
                          (system? #t))))
      (user-accounts (list (user-account
                            (name "messagebus")
                            (group "messagebus")
                            (system? #t)
                            (comment "D-Bus system bus user")
                            (home-directory "/var/run/dbus")
                            (shell
                             #~(string-append #$shadow "/sbin/nologin")))))
      (activate #~(begin
                    (use-modules (guix build utils))

                    (mkdir-p "/var/run/dbus")

                    (let ((user (getpwnam "messagebus")))
                      (chown "/var/run/dbus"
                             (passwd:uid user) (passwd:gid user)))

                    (unless (file-exists? "/etc/machine-id")
                      (format #t "creating /etc/machine-id...~%")
                      (let ((prog (string-append #$dbus "/bin/dbus-uuidgen")))
                        ;; XXX: We can't use 'system' because the initrd's
                        ;; guile system(3) only works when 'sh' is in $PATH.
                        (let ((pid (primitive-fork)))
                          (if (zero? pid)
                              (call-with-output-file "/etc/machine-id"
                                (lambda (port)
                                  (close-fdes 1)
                                  (dup2 (port->fdes port) 1)
                                  (execl prog)))
                              (waitpid pid)))))))))))


;;;
;;; Upower D-Bus service.
;;;

(define* (upower-configuration-file #:key watts-up-pro? poll-batteries?
                                    ignore-lid? use-percentage-for-policy?
                                    percentage-low percentage-critical
                                    percentage-action time-low
                                    time-critical time-action
                                    critical-power-action)
  "Return an upower-daemon configuration file."
  (text-file "UPower.conf"
             (string-append
              "[UPower]\n"
              "EnableWattsUpPro=" (bool watts-up-pro?)
              "NoPollBatteries=" (bool (not poll-batteries?))
              "IgnoreLid=" (bool ignore-lid?)
              "UsePercentageForPolicy=" (bool use-percentage-for-policy?)
              "PercentageLow=" (number->string percentage-low) "\n"
              "PercentageCritical=" (number->string percentage-critical) "\n"
              "PercentageAction=" (number->string percentage-action) "\n"
              "TimeLow=" (number->string time-low) "\n"
              "TimeCritical=" (number->string time-critical) "\n"
              "TimeAction=" (number->string time-action) "\n"
              "CriticalPowerAction=" (match critical-power-action
                                       ('hybrid-sleep "HybridSleep")
                                       ('hibernate "Hibernate")
                                       ('power-off "PowerOff"))
              "\n")))

(define* (upower-service #:key (upower upower)
                         (watts-up-pro? #f)
                         (poll-batteries? #t)
                         (ignore-lid? #f)
                         (use-percentage-for-policy? #f)
                         (percentage-low 10)
                         (percentage-critical 3)
                         (percentage-action 2)
                         (time-low 1200)
                         (time-critical 300)
                         (time-action 120)
                         (critical-power-action 'hybrid-sleep))
  "Return a service that runs @uref{http://upower.freedesktop.org/,
@command{upowerd}}, a system-wide monitor for power consumption and battery
levels, with the given configuration settings.  It implements the
@code{org.freedesktop.UPower} D-Bus interface, and is notably used by GNOME."
  (mlet %store-monad ((config (upower-configuration-file
                               #:watts-up-pro? watts-up-pro?
                               #:poll-batteries? poll-batteries?
                               #:ignore-lid? ignore-lid?
                               #:use-percentage-for-policy? use-percentage-for-policy?
                               #:percentage-low percentage-low
                               #:percentage-critical percentage-critical
                               #:percentage-action percentage-action
                               #:time-low time-low
                               #:time-critical time-critical
                               #:time-action time-action
                               #:critical-power-action critical-power-action)))
    (return
     (service
      (documentation "Run the UPower power and battery monitor.")
      (provision '(upower-daemon))
      (requirement '(dbus-system udev))

      (start #~(make-forkexec-constructor
                (list (string-append #$upower "/libexec/upowerd"))
                #:environment-variables
                (list (string-append "UPOWER_CONF_FILE_NAME=" #$config))))
      (stop #~(make-kill-destructor))
      (activate #~(begin
                    (use-modules (guix build utils))
                    (mkdir-p "/var/lib/upower")
                    (let ((user (getpwnam "upower")))
                      (chown "/var/lib/upower"
                             (passwd:uid user) (passwd:gid user)))))

      (user-groups (list (user-group
                          (name "upower")
                          (system? #t))))
      (user-accounts (list (user-account
                            (name "upower")
                            (group "upower")
                            (system? #t)
                            (comment "UPower daemon user")
                            (home-directory "/var/empty")
                            (shell
                             #~(string-append #$shadow "/sbin/nologin")))))))))


;;;
;;; Colord D-Bus service.
;;;

(define* (colord-service #:key (colord colord))
  "Return a service that runs @command{colord}, a system service with a D-Bus
interface to manage the color profiles of input and output devices such as
screens and scanners.  It is notably used by the GNOME Color Manager graphical
tool.  See @uref{http://www.freedesktop.org/software/colord/, the colord web
site} for more information."
  (with-monad %store-monad
    (return
     (service
      (documentation "Run the colord color management service.")
      (provision '(colord-daemon))
      (requirement '(dbus-system udev))

      (start #~(make-forkexec-constructor
                (list (string-append #$colord "/libexec/colord"))))
      (stop #~(make-kill-destructor))
      (activate #~(begin
                    (use-modules (guix build utils))
                    (mkdir-p "/var/lib/colord")
                    (let ((user (getpwnam "colord")))
                      (chown "/var/lib/colord"
                             (passwd:uid user) (passwd:gid user)))))

      (user-groups (list (user-group
                          (name "colord")
                          (system? #t))))
      (user-accounts (list (user-account
                            (name "colord")
                            (group "colord")
                            (system? #t)
                            (comment "colord daemon user")
                            (home-directory "/var/empty")
                            (shell
                             #~(string-append #$shadow "/sbin/nologin")))))))))


;;;
;;; GeoClue D-Bus service.
;;;

(define* (geoclue-application name #:key (allowed? #t) system? (users '()))
  "Configure default GeoClue access permissions for an application.  NAME is
the Desktop ID of the application, without the .desktop part.  If ALLOWED? is
true, the application will have access to location information by default.
The boolean SYSTEM? value indicates that an application is a system component
or not.  Finally USERS is a list of UIDs of all users for which this
application is allowed location info access.  An empty users list means all
users are allowed."
  (string-append
   "[" name "]\n"
   "allowed=" (bool allowed?)
   "system=" (bool system?)
   "users=" (string-join users ";") "\n"))

(define %standard-geoclue-applications
  (list (geoclue-application "gnome-datetime-panel" #:system? #t)
        (geoclue-application "epiphany" #:system? #f)
        (geoclue-application "firefox" #:system? #f)))

(define* (geoclue-configuration-file #:key whitelist wifi-geolocation-url
                                     submit-data?
                                     wifi-submission-url submission-nick
                                     applications)
  "Return a geoclue configuration file."
  (text-file "geoclue.conf"
             (string-append
              "[agent]\n"
              "whitelist=" (string-join whitelist ";") "\n"
              "[wifi]\n"
              "url=" wifi-geolocation-url "\n"
              "submit-data=" (bool submit-data?)
              "submission-url=" wifi-submission-url "\n"
              "submission-nick=" submission-nick "\n"
              (string-join applications "\n"))))

(define* (geoclue-service #:key (geoclue geoclue)
                          (whitelist '())
                          (wifi-geolocation-url
                           ;; Mozilla geolocation service:
                           "https://location.services.mozilla.com/v1/geolocate?key=geoclue")
                          (submit-data? #f)
                          (wifi-submission-url
                           "https://location.services.mozilla.com/v1/submit?key=geoclue")
                          (submission-nick "geoclue")
                          (applications %standard-geoclue-applications))
  "Return a service that runs the @command{geoclue} location service.  This
service provides a D-Bus interface to allow applications to request access to
a user's physical location, and optionally to add information to online
location databases.  By default, only the GNOME date-time panel and the Icecat
and Epiphany web browsers are able to ask for the user's location, and in the
case of Icecat and Epiphany, both will ask the user for permission first.  See
@uref{https://wiki.freedesktop.org/www/Software/GeoClue/, the geoclue web
site} for more information."
  (mlet %store-monad ((config (geoclue-configuration-file
                               #:whitelist whitelist
                               #:wifi-geolocation-url wifi-geolocation-url
                               #:submit-data? submit-data?
                               #:wifi-submission-url wifi-submission-url
                               #:submission-nick submission-nick
                               #:applications applications)))
    (return
     (service
      (documentation "Run the GeoClue location service.")
      (provision '(geoclue-daemon))
      (requirement '(dbus-system))

      (start #~(make-forkexec-constructor
                (list (string-append #$geoclue "/libexec/geoclue"))
                #:user "geoclue"
                #:environment-variables
                (list (string-append "GEOCLUE_CONFIG_FILE=" #$config))))
      (stop #~(make-kill-destructor))

      (user-groups (list (user-group
                          (name "geoclue")
                          (system? #t))))
      (user-accounts (list (user-account
                            (name "geoclue")
                            (group "geoclue")
                            (system? #t)
                            (comment "GeoClue daemon user")
                            (home-directory "/var/empty")
                            (shell
                             "/run/current-system/profile/sbin/nologin"))))))))


;;;
;;; Polkit privilege management service.
;;;

(define* (polkit-service #:key (polkit polkit))
  "Return a service that runs the @command{polkit} privilege management
service.  By querying the @command{polkit} service, a privileged system
component can know when it should grant additional capabilities to ordinary
users.  For example, an ordinary user can be granted the capability to suspend
the system if the user is logged in locally."
  (with-monad %store-monad
    (return
     (service
      (documentation "Run the polkit privilege management service.")
      (provision '(polkit-daemon))
      (requirement '(dbus-system))

      (start #~(make-forkexec-constructor
                (list (string-append #$polkit "/lib/polkit-1/polkitd"))))
      (stop #~(make-kill-destructor))

      (user-groups (list (user-group
                          (name "polkitd")
                          (system? #t))))
      (user-accounts (list (user-account
                            (name "polkitd")
                            (group "polkitd")
                            (system? #t)
                            (comment "Polkit daemon user")
                            (home-directory "/var/empty")
                            (shell
                             "/run/current-system/profile/sbin/nologin"))))

      (pam-services (list (unix-pam-service "polkit-1")))))))


;;;
;;; Elogind login and seat management service.
;;;

(define-record-type* <elogind-configuration> elogind-configuration
  make-elogind-configuration
  elogind-configuration
  (kill-user-processes?            elogind-kill-user-processes?
                                   (default #f))
  (kill-only-users                 elogind-kill-only-users
                                   (default '()))
  (kill-exclude-users              elogind-kill-exclude-users
                                   (default '("root")))
  (inhibit-delay-max-seconds       elogind-inhibit-delay-max-seconds
                                   (default 5))
  (handle-power-key                elogind-handle-power-key
                                   (default 'poweroff))
  (handle-suspend-key              elogind-handle-suspend-key
                                   (default 'suspend))
  (handle-hibernate-key            elogind-handle-hibernate-key
                                   ;; (default 'hibernate)
                                   ;; XXX Ignore it for now, since we don't
                                   ;; yet handle resume-from-hibernation in
                                   ;; our initrd.
                                   (default 'ignore))
  (handle-lid-switch               elogind-handle-lid-switch
                                   (default 'suspend))
  (handle-lid-switch-docked        elogind-handle-lid-switch-docked
                                   (default 'ignore))
  (power-key-ignore-inhibited?     elogind-power-key-ignore-inhibited?
                                   (default #f))
  (suspend-key-ignore-inhibited?   elogind-suspend-key-ignore-inhibited?
                                   (default #f))
  (hibernate-key-ignore-inhibited? elogind-hibernate-key-ignore-inhibited?
                                   (default #f))
  (lid-switch-ignore-inhibited?    elogind-lid-switch-ignore-inhibited?
                                   (default #t))
  (holdoff-timeout-seconds         elogind-holdoff-timeout-seconds
                                   (default 30))
  (idle-action                     elogind-idle-action
                                   (default 'ignore))
  (idle-action-seconds             elogind-idle-action-seconds
                                   (default (* 30 60)))
  (runtime-directory-size-percent  elogind-runtime-directory-size-percent
                                   (default 10))
  (runtime-directory-size          elogind-runtime-directory-size
                                   (default #f))
  (remove-ipc?                     elogind-remove-ipc?
                                   (default #t))

  (suspend-state                   elogind-suspend-state
                                   (default '("mem" "standby" "freeze")))
  (suspend-mode                    elogind-suspend-mode
                                   (default '()))
  (hibernate-state                 elogind-hibernate-state
                                   (default '("disk")))
  (hibernate-mode                  elogind-hibernate-mode
                                   (default '("platform" "shutdown")))
  (hybrid-sleep-state              elogind-hybrid-sleep-state
                                   (default '("disk")))
  (hybrid-sleep-mode               elogind-hybrid-sleep-mode
                                   (default
                                     '("suspend" "platform" "shutdown"))))

(define (elogind-configuration-file config)
  (define (yesno x)
    (match x
      (#t "yes")
      (#f "no")
      (_ (error "expected #t or #f, instead got:" x))))
  (define char-set:user-name
    (string->char-set "abcdefghijklmnopqrstuvwxyz0123456789_-"))
  (define (valid-list? l pred)
    (and-map (lambda (x) (string-every pred x)) l))
  (define (user-name-list users)
    (unless (valid-list? users char-set:user-name)
      (error "invalid user list" users))
    (string-join users " "))
  (define (enum val allowed)
    (unless (memq val allowed)
      (error "invalid value" val allowed))
    (symbol->string val))
  (define (non-negative-integer x)
    (unless (exact-integer? x) (error "not an integer" x))
    (when (negative? x) (error "negative number not allowed" x))
    (number->string x))
  (define handle-actions
    '(ignore poweroff reboot halt kexec suspend hibernate hybrid-sleep lock))
  (define (handle-action x)
    (enum x handle-actions))
  (define (sleep-list tokens)
    (unless (valid-list? tokens char-set:user-name)
      (error "invalid sleep list" tokens))
    (string-join tokens " "))
  (define-syntax ini-file-clause
    (syntax-rules ()
      ((_ config (prop (parser getter)))
       (string-append prop "=" (parser (getter config)) "\n"))
      ((_ config str)
       (string-append str "\n"))))
  (define-syntax-rule (ini-file config file clause ...)
    (text-file file (string-append (ini-file-clause config clause) ...)))
  (ini-file
   config "logind.conf"
   "[Login]"
   ("KillUserProcesses" (yesno elogind-kill-user-processes?))
   ("KillOnlyUsers" (user-name-list elogind-kill-only-users))
   ("KillExcludeUsers" (user-name-list elogind-kill-exclude-users))
   ("InhibitDelayMaxSecs" (non-negative-integer elogind-inhibit-delay-max-seconds))
   ("HandlePowerKey" (handle-action elogind-handle-power-key))
   ("HandleSuspendKey" (handle-action elogind-handle-suspend-key))
   ("HandleHibernateKey" (handle-action elogind-handle-hibernate-key))
   ("HandleLidSwitch" (handle-action elogind-handle-lid-switch))
   ("HandleLidSwitchDocked" (handle-action elogind-handle-lid-switch-docked))
   ("PowerKeyIgnoreInhibited" (yesno elogind-power-key-ignore-inhibited?))
   ("SuspendKeyIgnoreInhibited" (yesno elogind-suspend-key-ignore-inhibited?))
   ("HibernateKeyIgnoreInhibited" (yesno elogind-hibernate-key-ignore-inhibited?))
   ("LidSwitchIgnoreInhibited" (yesno elogind-lid-switch-ignore-inhibited?))
   ("HoldoffTimeoutSecs" (non-negative-integer elogind-holdoff-timeout-seconds))
   ("IdleAction" (handle-action elogind-idle-action))
   ("IdleActionSeconds" (non-negative-integer elogind-idle-action-seconds))
   ("RuntimeDirectorySize"
    (identity
     (lambda (config)
       (match (elogind-runtime-directory-size-percent config)
         (#f (non-negative-integer (elogind-runtime-directory-size config)))
         (percent (string-append (non-negative-integer percent) "%"))))))
   ("RemoveIpc" (yesno elogind-remove-ipc?))
   "[Sleep]"
   ("SuspendState" (sleep-list elogind-suspend-state))
   ("SuspendMode" (sleep-list elogind-suspend-mode))
   ("HibernateState" (sleep-list elogind-hibernate-state))
   ("HibernateMode" (sleep-list elogind-hibernate-mode))
   ("HybridSleepState" (sleep-list elogind-hybrid-sleep-state))
   ("HybridSleepMode" (sleep-list elogind-hybrid-sleep-mode))))

(define* (elogind-service #:key (elogind elogind)
                          (config (elogind-configuration)))
  "Return a service that runs the @command{elogind} login and seat management
service.  The @command{elogind} service integrates with PAM to allow other
system components to know the set of logged-in users as well as their session
types (graphical, console, remote, etc.).  It can also clean up after users
when they log out."
  (mlet %store-monad ((config-file (elogind-configuration-file config)))
    (return
     (service
      (documentation "Run the elogind login and seat management service.")
      (provision '(elogind))
      (requirement '(dbus-system))

      (start #~(make-forkexec-constructor
                (list (string-append #$elogind "/libexec/elogind/elogind"))
                #:environment-variables
                (list (string-append "ELOGIND_CONF_FILE=" #$config-file))))
      (stop #~(make-kill-destructor))))))


;;;
;;; The default set of desktop services.
;;;
(define %desktop-services
  ;; List of services typically useful for a "desktop" use case.
  (cons* (slim-service)

         (avahi-service)
         (wicd-service)
         (upower-service)
         ;; FIXME: The colord, geoclue, and polkit services could all be
         ;; bus-activated by default, so they don't run at program startup.
         ;; However, user creation and /var/lib/colord creation happen at
         ;; service activation time, so we currently add them to the set of
         ;; default services.
         (colord-service)
         (geoclue-service)
         (polkit-service)
         (elogind-service)
         (dbus-service (list avahi wicd upower colord geoclue polkit elogind))

         (ntp-service)

         (map (lambda (mservice)
                (mlet %store-monad ((service mservice))
                  (cond
                   ;; Provide an nscd ready to use nss-mdns.
                   ((memq 'nscd (service-provision service))
                    (nscd-service (nscd-configuration)
                                  #:name-services (list nss-mdns)))

                   ;; Add more rules to udev-service.
                   ;;
                   ;; XXX Keep this in sync with the 'udev-service' call in
                   ;; %base-services.  Here we intend only to add 'upower',
                   ;; 'colord', and 'elogind'.
                   ((memq 'udev (service-provision service))
                    (udev-service #:rules
                                  (list lvm2 fuse alsa-utils crda
                                        upower colord elogind)))

                   (else mservice))))
              %base-services)))

;;; desktop.scm ends here
