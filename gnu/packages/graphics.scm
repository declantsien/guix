;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2015 Ludovic Courtès <ludo@gnu.org>
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

(define-module (gnu packages graphics)
  #:use-module (guix download)
  #:use-module (guix svn-download)
  #:use-module (guix packages)
  #:use-module (guix build-system gnu)
  #:use-module (guix build-system cmake)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (gnu packages)
  #:use-module (gnu packages pkg-config)
  #:use-module (gnu packages compression)
  #:use-module (gnu packages multiprecision)
  #:use-module (gnu packages boost)
  #:use-module (gnu packages gl)
  #:use-module (gnu packages qt))

(define-public cgal
  (package
    (name "cgal")
    (version "4.5.1")
    (source (origin
              (method url-fetch)
              (uri (string-append
                    "http://gforge.inria.fr/frs/download.php/file/34402/CGAL-"
                    version ".tar.xz"))
              (sha256
               (base32
                "1565ycbds92bxmhi09avc1jl6ks141ig00j110l49gqxp9swy6zv"))))
    (build-system cmake-build-system)
    (arguments
     '(;; "RelWithDebInfo" is not supported.
       #:build-type "Release"

       ;; No 'test' target.
       #:tests? #f))
    (inputs
     `(("mpfr" ,mpfr)
       ("gmp" ,gmp)
       ("boost" ,boost)))
    (home-page "http://cgal.org/")
    (synopsis "Computational geometry algorithms library")
    (description
     "CGAL provides easy access to efficient and reliable geometric algorithms
in the form of a C++ library.  CGAL is used in various areas needing geometric
computation, such as: computer graphics, scientific visualization, computer
aided design and modeling, geographic information systems, molecular biology,
medical imaging, robotics and motion planning, mesh generation, numerical
methods, etc.  It provides data structures and algorithms such as
triangulations, Voronoi diagrams, polygons, polyhedra, mesh generation, and
many more.")

    ;; The 'LICENSE' file explains that a subset is available under more
    ;; permissive licenses.
    (license license:gpl3+)))

(define-public ilmbase
  (package
    (name "ilmbase")
    (version "2.2.0")
    (source (origin
              (method url-fetch)
              (uri (string-append "mirror://savannah/openexr/ilmbase-"
                                  version ".tar.gz"))
              (sha256
               (base32
                "1izddjwbh1grs8080vmaix72z469qy29wrvkphgmqmcm0sv1by7c"))))
    (build-system gnu-build-system)
    (home-page "http://www.openexr.com/")
    (synopsis "Utility C++ libraries for threads, maths, and exceptions")
    (description
     "IlmBase provides several utility libraries for C++.  Half is a class
that encapsulates ILM's 16-bit floating-point format.  IlmThread is a thread
abstraction.  Imath implements 2D and 3D vectors, 3x3 and 4x4 matrices,
quaternions and other useful 2D and 3D math functions.  Iex is an
exception-handling library.")
    (license license:bsd-3)))

(define-public openexr
  (package
    (name "openexr")
    (version "2.2.0")
    (source (origin
              (method url-fetch)
              (uri (string-append "mirror://savannah/openexr/openexr-"
                                  version ".tar.gz"))
              (sha256
               (base32
                "0ca2j526n4wlamrxb85y2jrgcv0gf21b3a19rr0gh4rjqkv1581n"))
              (modules '((guix build utils)))
              (snippet
               '(substitute* (find-files "." "tmpDir\\.h")
                  (("\"/var/tmp/\"")
                   "\"/tmp/\"")))
              (patches (list (search-patch "openexr-missing-samples.patch")))))
    (build-system gnu-build-system)
    (native-inputs
     `(("pkg-config" ,pkg-config)))
    (propagated-inputs
     `(("ilmbase" ,ilmbase)                       ;used in public headers
       ("zlib" ,zlib)))                           ;OpenEXR.pc reads "-lz"
    (home-page "http://www.openexr.com")
    (synopsis "High-dynamic range file format library")
    (description
     "OpenEXR is a high dynamic-range (HDR) image file format developed for
use in computer imaging applications.  The IlmImf C++ libraries support
storage of the \"EXR\" file format for storing 16-bit floating-point images.")
    (license license:bsd-3)))

(define-public ctl
  (package
    (name "ctl")
    (version "1.5.2")
    (source (origin
              (method url-fetch)
              (uri (string-append "https://github.com/ampas/CTL/archive/ctl-"
                                  version ".tar.gz"))
              (sha256
               (base32
                "1gg04pyvw0m398akn0s1l07g5b1haqv5na1wpi5dii1jjd1w3ynp"))))
    (build-system cmake-build-system)
    (arguments '(#:tests? #f))                    ;no 'test' target

    ;; Headers include OpenEXR and IlmBase headers.
    (propagated-inputs `(("openexr" ,openexr)))

    (home-page "http://ampasctl.sourceforge.net")
    (synopsis "Color Transformation Language")
    (description
     "The Color Transformation Language, or CTL, is a small programming
language that was designed to serve as a building block for digital color
management systems.  CTL allows users to describe color transforms in a
concise and unambiguous way by expressing them as programs.  In order to apply
a given transform to an image, the color management system instructs a CTL
interpreter to load and run the CTL program that describes the transform.  The
original and the transformed image constitute the CTL program's input and
output.")

    ;; The web site says it's under a BSD-3 license, but the 'LICENSE' file
    ;; and headers use different wording.
    (license (license:non-copyleft "file://LICENSE"))))

(define-public brdf-explorer
  (package
    (name "brdf-explorer")
    (version "17")                                ;svn revision
    (source (origin
              ;; There are no release tarballs, and not even tags in the repo,
              ;; so use the latest revision.
              (method svn-fetch)
              (uri (svn-reference
                    (url "http://github.com/wdas/brdf")
                    (revision (string->number version))))
              (sha256
               (base32
                "1458fwsqxramh0gpnp24x7brfpl9afhvr1wqg6c78xqwf32960m5"))
              (file-name (string-append name "-" version "-checkout"))))
    (build-system gnu-build-system)
    (arguments
     `(#:phases (modify-phases %standard-phases
                  (replace configure
                           (lambda* (#:key outputs #:allow-other-keys)
                             (let ((out (assoc-ref outputs "out")))
                               (chdir "trunk")
                               (zero? (system* "qmake"
                                               (string-append
                                                "prefix=" out))))))
                  (add-after install wrap-program
                             (lambda* (#:key outputs #:allow-other-keys)
                               (let* ((out (assoc-ref outputs "out"))
                                      (bin (string-append out "/bin"))
                                      (data (string-append
                                             out "/share/brdf")))
                                 (with-directory-excursion bin
                                   (rename-file "brdf" ".brdf-real")
                                   (call-with-output-file "brdf"
                                     (lambda (port)
                                       (format port "#!/bin/sh
# Run the thing from its home, otherwise it just bails out.
cd \"~a\"
exec -a \"$0\" ~a/.brdf-real~%"
                                               data bin)))
                                   (chmod "brdf" #o555))))))))
    (native-inputs
     `(("qt" ,qt-4)))                             ;for 'qmake'
    (inputs
     `(("qt" ,qt-4)
       ("mesa" ,mesa)
       ("glew" ,glew)
       ("freeglut" ,freeglut)
       ("zlib" ,zlib)))
    (home-page "http://www.disneyanimation.com/technology/brdf.html")
    (synopsis
     "Analyze bidirectional reflectance distribution functions (BRDFs)")
    (description
     "BRDF Explorer is an application that allows the development and analysis
of bidirectional reflectance distribution functions (BRDFs).  It can load and
plot analytic BRDF functions (coded as functions in OpenGL's GLSL shader
language), measured material data from the MERL database, and anisotropic
measured material data from MIT CSAIL.  Graphs and visualizations update in
real time as parameters are changed, making it a useful tool for evaluating
and understanding different BRDFs (and other component functions).")
    (license license:ms-pl)))
