/// <reference path="../pb_data/types.d.ts" />

// Adds the post-ride weather columns to the `rides` collection.
//
// Background: weather enrichment (temp/precip/wind/code + fetched-at marker)
// was added to the app's Ride model AFTER the initial `rides` collection was
// created (1780625000_init_rides.js). The app's toPocketBaseJson() sends these
// fields, but PocketBase SILENTLY DROPS unknown fields — so without these
// columns the weather never persists server-side and is wiped from the phone
// on the next pull / after a reinstall.
//
// All nullable: rides recorded before weather existed (or before the fetch
// completes) simply stay "weather-unknown". Mirrors the local SQLite v4
// migration in lib/data/database.dart.
//
// New migration file (higher timestamp) rather than editing the init
// migration — PocketBase only applies each migration filename once.

migrate(
  (db) => {
    const dao = new Dao(db);
    const collection = dao.findCollectionByNameOrId("rides");

    collection.schema.addField(
      new SchemaField({
        system: false,
        id: "fld_r_tmin0001",
        name: "temp_min_c",
        type: "number",
        required: false,
        presentable: false,
        unique: false,
        options: { min: null, max: null, noDecimal: false },
      })
    );
    collection.schema.addField(
      new SchemaField({
        system: false,
        id: "fld_r_tmax0001",
        name: "temp_max_c",
        type: "number",
        required: false,
        presentable: false,
        unique: false,
        options: { min: null, max: null, noDecimal: false },
      })
    );
    collection.schema.addField(
      new SchemaField({
        system: false,
        id: "fld_r_tavg0001",
        name: "temp_avg_c",
        type: "number",
        required: false,
        presentable: false,
        unique: false,
        options: { min: null, max: null, noDecimal: false },
      })
    );
    collection.schema.addField(
      new SchemaField({
        system: false,
        id: "fld_r_precip01",
        name: "precipitation_mm",
        type: "number",
        required: false,
        presentable: false,
        unique: false,
        options: { min: 0, max: null, noDecimal: false },
      })
    );
    collection.schema.addField(
      new SchemaField({
        system: false,
        id: "fld_r_wind0001",
        name: "wind_max_kmh",
        type: "number",
        required: false,
        presentable: false,
        unique: false,
        options: { min: 0, max: null, noDecimal: false },
      })
    );
    collection.schema.addField(
      new SchemaField({
        system: false,
        id: "fld_r_wcode001",
        name: "weather_code",
        type: "number",
        required: false,
        presentable: false,
        unique: false,
        options: { min: null, max: null, noDecimal: true },
      })
    );
    collection.schema.addField(
      new SchemaField({
        system: false,
        id: "fld_r_wfetch01",
        name: "weather_fetched_at",
        type: "text",
        required: false,
        presentable: false,
        unique: false,
        options: { min: null, max: null, pattern: "" },
      })
    );

    return dao.saveCollection(collection);
  },
  (db) => {
    const dao = new Dao(db);
    const collection = dao.findCollectionByNameOrId("rides");
    for (const id of [
      "fld_r_tmin0001",
      "fld_r_tmax0001",
      "fld_r_tavg0001",
      "fld_r_precip01",
      "fld_r_wind0001",
      "fld_r_wcode001",
      "fld_r_wfetch01",
    ]) {
      collection.schema.removeField(id);
    }
    return dao.saveCollection(collection);
  }
);
