/*
 * proplist-cmd.c -- List properties of files/dirs
 *
 * ====================================================================
 * Copyright (c) 2000-2002 CollabNet.  All rights reserved.
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
 */

/* ==================================================================== */



/*** Includes. ***/

#include "svn_wc.h"
#include "svn_client.h"
#include "svn_string.h"
#include "svn_path.h"
#include "svn_delta.h"
#include "svn_error.h"
#include "svn_utf.h"
#include "cl.h"


/*** Code. ***/

/* This implements the `svn_opt_subcommand_t' interface. */
svn_error_t *
svn_cl__proplist (apr_getopt_t *os,
                  void *baton,
                  apr_pool_t *pool)
{
  svn_cl__opt_state_t *opt_state = baton;
  apr_array_header_t *targets;
  int i;

  /* Suck up all remaining args in the target array. */
  SVN_ERR (svn_opt_args_to_target_array (&targets, os, 
                                         opt_state->targets,
                                         &(opt_state->start_revision),
                                         &(opt_state->end_revision),
                                         FALSE, pool));

  /* Add "." if user passed 0 arguments */
  svn_opt_push_implicit_dot_target (targets, pool);


  /* Decide if we're listing local, versioned working copy props, or
     listing unversioned revision props in the repository.  The
     existence of the '-r' flag is the key. */
  if (opt_state->start_revision.kind != svn_opt_revision_unspecified)
    {
      svn_revnum_t rev;
      const char *URL, *target;
      svn_boolean_t is_url;
      svn_client_auth_baton_t *auth_baton;
      apr_hash_t *proplist;

      auth_baton = svn_cl__make_auth_baton (opt_state, pool);

      /* Either we have a URL target, or an implicit wc-path ('.')
         which needs to be converted to a URL. */
      if (targets->nelts <= 0)
        return svn_error_create(SVN_ERR_CL_INSUFFICIENT_ARGS, 0, NULL, pool,
                                "No URL target available.");
      target = ((const char **) (targets->elts))[0];
      is_url = svn_path_is_url (target);
      if (is_url)
        {
          URL = target;
        }
      else
        {
          svn_wc_adm_access_t *adm_access;          
          const svn_wc_entry_t *entry;
          SVN_ERR (svn_wc_adm_probe_open (&adm_access, NULL, target,
                                          FALSE, FALSE, pool));
          SVN_ERR (svn_wc_entry (&entry, target, adm_access, FALSE, pool));
          SVN_ERR (svn_wc_adm_close (adm_access));
          URL = entry->url;
        }

      /* Let libsvn_client do the real work. */
      SVN_ERR (svn_client_revprop_list (&proplist, 
                                        URL, &(opt_state->start_revision),
                                        auth_baton, &rev, pool));
      
      printf("Unversioned properties on revision %"SVN_REVNUM_T_FMT":\n",
             rev);
      if (opt_state->verbose)
        SVN_ERR (svn_cl__print_prop_hash (proplist, pool));
      else
        SVN_ERR (svn_cl__print_prop_names (proplist, pool));
    }

  else  /* local working copy proplist */
    {
      for (i = 0; i < targets->nelts; i++)
        {
          const char *target = ((const char **) (targets->elts))[i];
          apr_array_header_t *props;
          int j;
          
          SVN_ERR (svn_client_proplist (&props, target, 
                                        opt_state->recursive, pool));
          
          for (j = 0; j < props->nelts; ++j)
            {
              svn_client_proplist_item_t *item 
                = ((svn_client_proplist_item_t **)props->elts)[j];
              const char *node_name_native;
              SVN_ERR (svn_utf_cstring_from_utf8_stringbuf (&node_name_native,
                                                            item->node_name,
                                                            pool));
              printf("Properties on '%s':\n", node_name_native);
              if (opt_state->verbose)
                SVN_ERR (svn_cl__print_prop_hash (item->prop_hash, pool));
              else
                SVN_ERR (svn_cl__print_prop_names (item->prop_hash, pool));
            }
        }
    }

  return SVN_NO_ERROR;
}


/* 
 * local variables:
 * eval: (load-file "../../../tools/dev/svn-dev.el")
 * end: 
 */
