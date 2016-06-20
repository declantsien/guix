;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2016 Ludovic Courtès <ludo@gnu.org>
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

(define-module (gnu tests base)
  #:use-module (gnu tests)
  #:use-module (gnu system)
  #:use-module (gnu system grub)
  #:use-module (gnu system file-systems)
  #:use-module (gnu system shadow)
  #:use-module (gnu system vm)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:use-module (guix store)
  #:use-module (guix monads)
  #:use-module (guix packages)
  #:use-module (srfi srfi-1)
  #:export (run-basic-test
            %test-basic-os))

(define %simple-os
  (operating-system
    (host-name "komputilo")
    (timezone "Europe/Berlin")
    (locale "en_US.UTF-8")

    (bootloader (grub-configuration (device "/dev/sdX")))
    (file-systems (cons (file-system
                          (device "my-root")
                          (title 'label)
                          (mount-point "/")
                          (type "ext4"))
                        %base-file-systems))
    (firmware '())

    (users (cons (user-account
                  (name "alice")
                  (comment "Bob's sister")
                  (group "users")
                  (supplementary-groups '("wheel" "audio" "video"))
                  (home-directory "/home/alice"))
                 %base-user-accounts))))


(define* (run-basic-test os command #:optional (name "basic"))
  "Return a derivation called NAME that tests basic features of the OS started
using COMMAND, a gexp that evaluates to a list of strings.  Compare some
properties of running system to what's declared in OS, an <operating-system>."
  (define test
    #~(begin
        (use-modules (gnu build marionette)
                     (srfi srfi-1)
                     (srfi srfi-26)
                     (srfi srfi-64)
                     (ice-9 match))

        (define marionette
          (make-marionette #$command))

        (mkdir #$output)
        (chdir #$output)

        (test-begin "basic")

        (test-assert "uname"
          (match (marionette-eval '(uname) marionette)
            (#("Linux" host-name version _ "x86_64")
             (and (string=? host-name
                            #$(operating-system-host-name os))
                  (string-prefix? #$(package-version
                                     (operating-system-kernel os))
                                  version)))))

        (test-assert "shell and user commands"
          ;; Is everything in $PATH?
          (zero? (marionette-eval '(system "
. /etc/profile
set -e -x
guix --version
ls --version
grep --version
info --version")
                                  marionette)))

        (test-assert "accounts"
          (let ((users (marionette-eval '(begin
                                           (use-modules (ice-9 match))
                                           (let loop ((result '()))
                                             (match (getpw)
                                               (#f (reverse result))
                                               (x  (loop (cons x result))))))
                                        marionette)))
            (lset= string=?
                   (map passwd:name users)
                   (list
                    #$@(map user-account-name
                            (operating-system-user-accounts os))))))

        (test-assert "shepherd services"
          (let ((services (marionette-eval '(begin
                                              (use-modules (gnu services herd))
                                              (call-with-values current-services
                                                append))
                                           marionette)))
            (lset= eq?
                   (pk 'services services)
                   '(root #$@(operating-system-shepherd-service-names os)))))

        (test-equal "login on tty1"
          "root\n"
          (begin
            (marionette-control "sendkey ctrl-alt-f1" marionette)
            ;; Wait for the 'term-tty1' service to be running (using
            ;; 'start-service' is the simplest and most reliable way to do
            ;; that.)
            (marionette-eval
             '(begin
                (use-modules (gnu services herd))
                (start-service 'term-tty1))
             marionette)

            ;; Now we can type.
            (marionette-type "root\n\nid -un > logged-in\n" marionette)

            ;; It can take a while before the shell commands are executed.
            (let loop ((i 0))
              (unless (or (file-exists? "/root/logged-in") (> i 15))
                (sleep 1)
                (loop (+ i 1))))
            (marionette-eval '(use-modules (rnrs io ports)) marionette)
            (marionette-eval '(call-with-input-file "/root/logged-in"
                                get-string-all)
                             marionette)))

        (test-assert "screendump"
          (begin
            (marionette-control (string-append "screendump " #$output
                                               "/tty1.ppm")
                                marionette)
            (file-exists? "tty1.ppm")))

        (test-end)
        (exit (= (test-runner-fail-count (test-runner-current)) 0))))

  (gexp->derivation name test
                    #:modules '((gnu build marionette))))

(define %test-basic-os
  (system-test
   (name "basic")
   (description
    "Instrument %SIMPLE-OS, run it in a VM, and runs a series of basic
functionality tests.")
   (value
    (mlet* %store-monad ((os -> (marionette-operating-system
                                 %simple-os
                                 #:imported-modules '((gnu services herd)
                                                      (guix combinators))))
                         (run   (system-qemu-image/shared-store-script
                                 os #:graphic? #f)))
      ;; XXX: Add call to 'virtualized-operating-system' to get the exact same
      ;; set of services as the OS produced by
      ;; 'system-qemu-image/shared-store-script'.
      (run-basic-test (virtualized-operating-system os '())
                      #~(list #$run))))))
