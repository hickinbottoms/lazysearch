/* Remove lazification from the database. Useful for testing to force
 * relazification as the database is restarted.
 * Copyright © Stuart Hickinbottom 2004-2007
 * 
 * This file is part of LazySearch2.
 * 
 * LazySearch2 is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 * 
 * LazySearch2 is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 * 
 * You should have received a copy of the GNU General Public License
 * along with Foobar; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
 *
 * $Id$
 */
update albums set customsearch = null;
update contributors set customsearch = null;
update genres set customsearch = null;
update tracks set customsearch = null;
