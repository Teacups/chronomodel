------------------------------------------------------
-- Temporal schema for an example "countries" relation
--
-- http://github.com/ifad/chronomodel
--
create schema temporal; -- schema containing all temporal tables
create schema history;  -- schema containing all history tables

-- Current countries data - nothing special
--
create table temporal.countries (
  id   serial primary key,
  name varchar
);

-- Countries historical data.
--
-- Inheritance is used to avoid duplicating the schema from the main table.
-- Please note that columns on the main table cannot be dropped, and other caveats
-- http://www.postgresql.org/docs/9.0/static/ddl-inherit.html#DDL-INHERIT-CAVEATS
--
create table history.countries (
  hid         serial primary key,
  validity    tsrange,
  recorded_at timestamp not null default timezone('UTC', now()),

  constraint overlapping_times exclude using gist ( id with =, validity with && )

) inherits ( temporal.countries );

-- Inherited primary key
create index country_inherit_pkey on history.countries ( id );

-- Snapshot of data at a specific point in time
create index country_snapshot on history.countries USING gist ( validity );

-- Used by the trigger functions when UPDATE'ing and DELETE'ing
create index country_lower_validity on history.countries ( lower(validity) )
create index country_upper_validity on history.countries ( upper(validity) )
create index country_recorded_at    on history.countries ( id, valid_to )

-- Single instance whole history
create index country_instance_history on history.countries ( id, recorded_at )


-- The countries view, what the Rails' application ORM will actually CRUD on, and
-- the core of the temporal updates.
--
-- SELECT - return only current data
--
create view public.countries as select * from only temporal.countries;

-- INSERT - insert data both in the current data table and in the history one.
--
create or replace function public.chronomodel_countries_insert() returns trigger as $$
  begin
    insert into temporal.countries ( name, valid_from )
    values ( new.name )
    returning id into new.id;

    insert into history.countries ( id, name, validity )
    values ( new.id, new.name, tsrange(timezone('utc', now()), null) );

    return new;
  end;
$$ language plpgsql;

create trigger chronomodel_insert instead of insert on public.countries
  for each row execute procedure public.chronomodel_countries_insert();

-- UPDATE - set the last history entry validity to now, save the current data
-- in a new history entry and update the temporal table with the new data.
--
-- If a row in the history with the current ID and current timestamp already
-- exists, update it with new data. This logic makes possible to "squash"
-- together changes made in a transaction in a single history row.
--
create function chronomodel_countries_update() returns trigger as $$
  declare _now timestamp;
  declare _hid integer;
  begin
    _now := timezone('utc', now());
    _hid := null;

    select hid into _hid from history.countries where id = old.id and lower(validity) = _now;

    if _hid is not null then
      update history.countries set name = new.name where hid = _hid;
    else
      update history.countries set validity = tsrange(lower(validity), _now)
      where id = old.id and upper_inf(validity);

      insert into history.countries ( id, name, validity )
      values ( old.id, new.values, tsrange(_now, null) );
    end if;

    update only temporal.countries set name = new.name where id = old.id;

    return new;
  end;
$$ language plpgsql;

create trigger chronomodel_update instead of update on countries
  for each row execute procedure chronomodel_countries_update();

-- DELETE - save the current data in the history and eventually delete the
-- data from the temporal table.
-- The first DELETE is required to remove history for records INSERTed and
-- DELETEd in the same transaction.
--
create or replace function chronomodel_countries_delete() returns trigger as $$
  declare _now timestamp;
  begin
    _now := timezone('utc', now());

    delete from history.countries
    where id = old.id and validity = tsrange(_now, null);

    update history.countries set valid_to = _now
    where id = old.id and upper_inf(validity);

    delete from only temporal.countries
    where temporal.id = old.id;

    return null;
  end;
$$ language plpgsql;

create trigger chronomodel_delete instead of delete on countries
  for each row execute procedure chronomodel_countries_delete();

-- EOF
