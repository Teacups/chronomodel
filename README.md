# ChronoModel

A temporal database system on PostgreSQL using
[views](http://www.postgresql.org/docs/9.3/static/sql-createview.html),
[table inheritance](http://www.postgresql.org/docs/9.3/static/ddl-inherit.html) and
[INSTEAD OF triggers](http://www.postgresql.org/docs/9.3/static/sql-createtrigger.html)

This is a data structure for a
[Slowly-Changing Dimension Type 2](http://en.wikipedia.org/wiki/Slowly_changing_dimension#Type_2)
temporal database, implemented using [PostgreSQL](http://www.postgresql.org) &gt;= 9.3 features.

[![Build Status](https://travis-ci.org/ifad/chronomodel.png?branch=master)](https://travis-ci.org/ifad/chronomodel)
[![Dependency Status](https://gemnasium.com/ifad/chronomodel.png)](https://gemnasium.com/ifad/chronomodel)
[![Code Climate](https://codeclimate.com/github/ifad/chronomodel.png)](https://codeclimate.com/github/ifad/chronomodel)

All the history recording is done inside the database system, freeing the application code from
having to deal with it.

The application model is backed by an updatable view that behaves exactly like a plain table, while
behind the scenes the database redirects the queries to concrete tables using
[triggers](http://www.postgresql.org/docs/9.3/static/trigger-definition.html).

Current data is hold in a table in the `temporal` [schema](http://www.postgresql.org/docs/9.3/static/ddl-schemas.html),
while history in hold in another table in the `history` schema. The latter
[inherits](http://www.postgresql.org/docs/9.3/static/ddl-inherit.html) from the former, to get
automated schema updates for free. Partitioning of history is even possible but not implemented
yet.

The updatable view is created in the default `public` schema, making it visible to Active Record.

All Active Record schema migration statements are decorated with code that handles the temporal
structure by e.g. keeping the triggers in sync or dropping/recreating it when required by your
migrations.

Data extraction at a single point in time and even `JOIN`s between temporal and non-temporal data
is implemented using sub-selects and a `WHERE` generated by the provided `TimeMachine` module to
be included in your models.

The `WHERE` is optimized using a spatial GiST index in which time is represented represented by
boxes and the filtering is done using the overlapping (`&&`) geometry operator.

All timestamps are (forcibly) stored in the UTC time zone, bypassing the `AR::Base.config.default_timezone`
setting.

See [README.sql](https://github.com/ifad/chronomodel/blob/master/README.sql) for the plain SQL
defining this temporal schema for a single table.


## Requirements

* Ruby &gt;= 1.9.2
* Active Record &gt;= 3.2
* PostgreSQL &gt;= 9.3


## Installation

Add this line to your application's Gemfile:

    gem 'chrono_model', :git => 'git://github.com/ifad/chronomodel'

And then execute:

    $ bundle

## Configuration

Configure your `config/database.yml` to use the `chronomodel` adapter:

    development:
      adapter: chronomodel
      username: ...

## Schema creation

This library hooks all `ActiveRecord::Migration` methods to make them temporal aware.

The only option added is `:temporal => true` to `create_table`:

    create_table :countries, :temporal => true do |t|
      t.string :common_name
      t.references :currency
      # ...
    end

That'll create the _current_, its _history_ child table and the _public_ view.
Every other housekeeping of the temporal structure is handled behind the scenes
by the other schema statements. E.g.:

 * `rename_table`  - renames tables, views, sequences, indexes and triggers
 * `drop_table`    - drops the temporal table and all dependant objects
 * `add_column`    - adds the column to the current table and updates triggers
 * `rename_column` - renames the current table column and updates the triggers
 * `remove_column` - removes the current table column and updates the triggers
 * `add_index`     - creates the index in the history table as well
 * `remove_index`  - removes the index from the history table as well


## Adding Temporal extensions to an existing table

Use `change_table`:

    change_table :your_table, :temporal => true

If you want to also set up the history from your current data:

    change_table :your_table, :temporal => true, :copy_data => true

This will create an history record for each record in your table, setting its
validity from midnight, January 1st, 1 CE. You can set a specific validity
with the `:validity` option:

    change_table :your_table, :temporal => true, :copy_data => true, :validity => '1977-01-01'


## Data querying

A model backed by a temporal view will behave like any other model backed by a
plain table. If you want to do as-of-date queries, you need to include the
`ChronoModel::TimeMachine` module in your model.

    module Country < ActiveRecord::Base
      include ChronoModel::TimeMachine

      has_many :compositions
    end

This will create a `Country::History` model inherited from `Country`, and it
will make an `as_of` class method available to your model. E.g.:

    Country.as_of(1.year.ago)

Will execute:

    SELECT "countries".* FROM (
      SELECT "history"."countries".* FROM "history"."countries"
      WHERE box(
        point( date_part( 'epoch', '#{1.year.ago.utc}'::timestamp ), 0 ),
        point( date_part( 'epoch', '#{1.year.ago.utc}'::timestamp ), 0 )
      ) &&
      box(
        point( date_part( 'epoch', "history"."addresses"."valid_from" ), 0 ),
        point( date_part( 'epoch', "history"."addresses"."valid_to"   ), 0 ),
      )
    ) AS "countries"

This work on associations using temporal extensions as well:

    Country.as_of(1.year.ago).first.compositions

Will execute:

    # ... countries history query ...
    LIMIT 1

    SELECT * FROM  (
      SELECT "history"."compositions".* FROM "history"."compositions"
      WHERE box(
        point( date_part( 'epoch', '#{above_timestamp}'::timestamp ), 0 ),
        point( date_part( 'epoch', '#{above_timestamp}'::timestamp ), 0 )
      ) &&
      box(
        point( date_part( 'epoch', "history"."addresses"."valid_from" ), 0 ),
        point( date_part( 'epoch', "history"."addresses"."valid_to"   ), 0 ),
      )
    ) AS "compositions" WHERE country_id = X

And `.joins` works as well:

    Country.as_of(1.month.ago).joins(:compositions)

Will execute:

    SELECT "countries".* FROM (
      # .. countries history query ..
    ) AS "countries" INNER JOIN (
      # .. compositions history query ..
    ) AS "compositions" ON compositions.country_id = countries.id

More methods are provided, see the
[TimeMachine](https://github.com/ifad/chronomodel/blob/master/lib/chrono_model/time_machine.rb) source
for more information.


## Running tests

You need a running Postgresql instance. Create `spec/config.yml` with the
connection authentication details (use `spec/config.yml.example` as template).

Run `rake`. SQL queries are logged to `spec/debug.log`. If you want to see
them in your output, use `rake VERBOSE=true`.

## Caveats

 * The triggers and temporal indexes cannot be saved in schema.rb. The AR
   schema dumper is quite basic, and it isn't (currently) extensible.
   As we're using many database-specific features, Chronomodel forces the
   usage of the `:sql` schema dumper, and included rake tasks override
   `db:schema:dump` and `db:schema:load` to do `db:structure:dump` and
   `db:structure:load`. Two helper tasks are also added, `db:data:dump`
   and `db:data:load`.

 * `.includes` is quirky when using `.as_of`.

 * The history queries are very verbose, they should be factored out using a
   `FUNCTION`.

 * The choice of using subqueries instead of [Common Table Expressions](http://www.postgresql.org/docs/9.3/static/queries-with.html)
   was dictated by the fact that CTEs [currently acts as an optimization
   fence](http://archives.postgresql.org/pgsql-hackers/2012-09/msg00700.php).
   If it will be possible [to opt-out of the
   fence](http://archives.postgresql.org/pgsql-hackers/2012-10/msg00024.php)
   in the future, they will be probably be used again as they were [in the
   past](https://github.com/ifad/chronomodel/commit/18f4c4b), because the
   resulting queries are much more readable, and do not inhibit using
   `.from()` from ARel.


## Contributing

 1. Fork it
 2. Create your feature branch (`git checkout -b my-new-feature`)
 3. Commit your changes (`git commit -am 'Added some feature'`)
 4. Push to the branch (`git push origin my-new-feature`)
 5. Create new Pull Request
