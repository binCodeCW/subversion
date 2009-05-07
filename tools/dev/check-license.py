#!/usr/bin/env python
#
# check if a file has the proper license in it
#
# USAGE: check-license.py [-C] file1 file2 ... fileN
#
# A 'file' may in fact be a directory, in which case it is recursively
# searched.
#
# If the license cannot be found, then the filename is printed to stdout.
# Typical usage:
#    $ check-license.py . > bad-files
#
# -C switch is used to change licenses.
# Typical usage:
#    $ check-license.py -C file1 file2 ... fileN
#

import sys, os, re

OLD_LICENSE = '''\
 \* ====================================================================
 \* Copyright \(c\) (200[0-9]|200[0-9]-200[0-9]) CollabNet.  All rights reserved.
 \*
 \* This software is licensed as described in the file COPYING, which
 \* you should have received as part of this distribution\.  The terms
 \* are also available at http://subversion.tigris.org/license-1\.html\.
 \* If newer versions of this license are posted there, you may use a
 \* newer version instead, at your option\.
 \*
 \* This software consists of voluntary contributions made by many
 \* individuals\.  For exact contribution history, see the revision
 \* history and logs, available at http://subversion.tigris.org/\.
 \* ====================================================================
'''

SH_OLD_LICENSE = re.subn(r'(?m)^ \\\*', '#', OLD_LICENSE)[0]

# Remember not to do regexp quoting for NEW_LICENSE.  Only OLD_LICENSE
# is used for matching; NEW_LICENSE is inserted as-is.
NEW_LICENSE = '''\
 * ====================================================================
 * Copyright (c) 2000-2009 CollabNet.  All rights reserved.
 *
 * This software is licensed as described in the file COPYING, which
 * you should have received as part of this distribution.  The terms
 * are also available at http://subversion.tigris.org/license-1.html.
 * If newer versions of this license are posted there, you may use a
 * newer version instead, at your option.
 *
 * This software consists of voluntary contributions made by many
 * individuals.  For exact contribution history, see the revision
 * history and logs, available at http://subversion.tigris.org/.
 * ====================================================================
'''

SH_NEW_LICENSE = re.subn(r'(?m)^ \*', '#', NEW_LICENSE)[0]

re_OLD = re.compile(OLD_LICENSE)
re_SH_OLD = re.compile(SH_OLD_LICENSE)
re_EXCLUDE = re.compile(
    r'automatically generated by SWIG'
    + r'|Generated from configure\.in'
    + r'|placed into the public domain'
    )

c_comment_suffices = ('.c', '.java', '.h', '.cpp', '.hw', '.pas')

# Yes, this is an empty tuple. No types that fit in this category uniformly
# have a copyright block.
# Possible types to add here:
# ('.bat', '.py', '.pl', '.in')
sh_comment_suffices = ()

def check_file(fname, old_re, new_lic):
  s = open(fname).read()
  if (not old_re.search(s)
      and not re_EXCLUDE.search(s)):
    print(fname)

def change_license(fname, old_re, new_lic):
  s = open(fname).read()
  m = old_re.search(s)
  if not m:
    print('ERROR: missing old license: %s' % fname)
  else:
    s = s[:m.start()] + new_lic + s[m.end():]
    open(fname, 'w').write(s)
    print('Changed: %s' % fname)

def visit(baton, dirname, dircontents):
  file_func = baton
  for i in dircontents:
    # Don't recurse into certain directories
    if i in ('.svn', '.libs'):
      dircontents.remove(i)
      continue

    extension = os.path.splitext(i)[1]
    fullname = os.path.join(dirname, i)

    if os.path.isdir(fullname):
      continue

    if extension in c_comment_suffices:
      file_func(fullname, re_OLD, NEW_LICENSE)
    elif extension in sh_comment_suffices:
      file_func(fullname, re_SH_OLD, SH_NEW_LICENSE)

def main():
  file_func = check_file
  if sys.argv[1] == '-C':
    print('Changing license text...')
    del sys.argv[1]
    file_func = change_license

  for f in sys.argv[1:]:
    if os.path.isdir(f):
      baton = file_func
      for dirpath, dirs, files in os.walk(f):
        visit(baton, dirpath, dirs + files)
    else:
      baton = file_func
      dir, i = os.path.split(f)
      visit(baton, dir, i)

if __name__ == '__main__':
  main()
