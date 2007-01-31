/* Remove lazification from the database. Useful for testing to force
 * relazification as the database is restarted.
 *
 * $Id$
 */
update albums set customsearch = null;
update contributors set customsearch = null;
update genres set customsearch = null;
update tracks set customsearch = null;
