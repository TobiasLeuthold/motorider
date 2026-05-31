/// <reference path="../pb_data/types.d.ts" />

// Initial schema for the `fillups` collection.
//
// Sync model: the client (Flutter app) is the source of truth for `id`
// (UUID v4) and `updated_at` (ISO timestamp set on every local write).
// The server stores them verbatim. Sync uses last-write-wins keyed on
// (client_id, updated_at) — see SyncService on the app side.
//
// Soft deletes: `deleted_at` non-null means tombstone. The app filters
// these out of normal queries but still pulls them so other devices
// converge on the deletion.

migrate(
  (db) => {
    const collection = new Collection({
      id: "pbc_fillups0001",
      name: "fillups",
      type: "base",
      system: false,
      schema: [
        {
          system: false,
          id: "fld_clientid01",
          name: "client_id",
          type: "text",
          required: true,
          presentable: true,
          unique: false,
          options: { min: 36, max: 36, pattern: "" },
        },
        {
          system: false,
          id: "fld_dateiso001",
          name: "date_iso",
          type: "text",
          required: true,
          presentable: false,
          unique: false,
          options: { min: null, max: null, pattern: "" },
        },
        {
          system: false,
          id: "fld_odokm00001",
          name: "odometer_km",
          type: "number",
          required: true,
          presentable: false,
          unique: false,
          options: { min: 0, max: null, noDecimal: true },
        },
        {
          system: false,
          id: "fld_liters0001",
          name: "liters",
          type: "number",
          required: true,
          presentable: false,
          unique: false,
          options: { min: 0, max: null, noDecimal: false },
        },
        {
          system: false,
          id: "fld_totalchf01",
          name: "total_chf",
          type: "number",
          required: true,
          presentable: false,
          unique: false,
          options: { min: 0, max: null, noDecimal: false },
        },
        {
          system: false,
          id: "fld_latitude01",
          name: "latitude",
          type: "number",
          required: false,
          presentable: false,
          unique: false,
          options: { min: -90, max: 90, noDecimal: false },
        },
        {
          system: false,
          id: "fld_longitud01",
          name: "longitude",
          type: "number",
          required: false,
          presentable: false,
          unique: false,
          options: { min: -180, max: 180, noDecimal: false },
        },
        {
          system: false,
          id: "fld_station001",
          name: "station",
          type: "text",
          required: false,
          presentable: false,
          unique: false,
          options: { min: null, max: null, pattern: "" },
        },
        {
          system: false,
          id: "fld_notes00001",
          name: "notes",
          type: "text",
          required: false,
          presentable: false,
          unique: false,
          options: { min: null, max: null, pattern: "" },
        },
        {
          system: false,
          id: "fld_fulltank01",
          name: "full_tank",
          type: "bool",
          required: false,
          presentable: false,
          unique: false,
          options: {},
        },
        {
          system: false,
          id: "fld_updatedat1",
          name: "updated_at",
          type: "text",
          required: true,
          presentable: false,
          unique: false,
          options: { min: null, max: null, pattern: "" },
        },
        {
          system: false,
          id: "fld_deletedat1",
          name: "deleted_at",
          type: "text",
          required: false,
          presentable: false,
          unique: false,
          options: { min: null, max: null, pattern: "" },
        },
      ],
      indexes: [
        "CREATE UNIQUE INDEX `idx_fillups_client_id` ON `fillups` (`client_id`)",
        "CREATE INDEX `idx_fillups_updated_at` ON `fillups` (`updated_at`)",
      ],
      // v1 access: any authenticated user can read/write. Behind Tailscale
      // + a single dedicated app user, this is effectively single-user.
      // Tighten to `@request.auth.id = "<your_user_id>"` once you create it.
      listRule:   "@request.auth.id != \"\"",
      viewRule:   "@request.auth.id != \"\"",
      createRule: "@request.auth.id != \"\"",
      updateRule: "@request.auth.id != \"\"",
      deleteRule: "@request.auth.id != \"\"",
      options: {},
    });

    return Dao(db).saveCollection(collection);
  },
  (db) => {
    const dao = new Dao(db);
    const collection = dao.findCollectionByNameOrId("fillups");
    return dao.deleteCollection(collection);
  }
);
