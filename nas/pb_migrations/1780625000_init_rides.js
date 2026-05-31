/// <reference path="../pb_data/types.d.ts" />

// `rides` collection. Stores both ride metadata (distance, durations, max
// speed etc.) and the entire GPS polyline as a JSON blob in `points_json`.
//
// Why a blob and not a child collection: a typical 2-hour ride at 1 Hz GPS
// is ~7000 points. Pushing those as individual records would be 7000 round
// trips per ride. As a single JSON-tuple array it's ~200KB and one POST.
// Trade-off accepted: we can't query individual points server-side. We
// don't need to — the phone reads the whole ride at once.

migrate(
  (db) => {
    const collection = new Collection({
      id: "pbc_rides00001",
      name: "rides",
      type: "base",
      system: false,
      schema: [
        {
          system: false,
          id: "fld_r_clientid",
          name: "client_id",
          type: "text",
          required: true,
          presentable: true,
          unique: false,
          options: { min: 1, max: null, pattern: "" },
        },
        {
          system: false,
          id: "fld_r_started1",
          name: "started_at",
          type: "text",
          required: true,
          presentable: false,
          unique: false,
          options: { min: null, max: null, pattern: "" },
        },
        {
          system: false,
          id: "fld_r_ended001",
          name: "ended_at",
          type: "text",
          required: false,
          presentable: false,
          unique: false,
          options: { min: null, max: null, pattern: "" },
        },
        {
          system: false,
          id: "fld_r_distkm01",
          name: "distance_km",
          type: "number",
          required: false,
          presentable: false,
          unique: false,
          options: { min: 0, max: null, noDecimal: false },
        },
        {
          system: false,
          id: "fld_r_totaldur",
          name: "total_duration_s",
          type: "number",
          required: false,
          presentable: false,
          unique: false,
          options: { min: 0, max: null, noDecimal: true },
        },
        {
          system: false,
          id: "fld_r_movedur1",
          name: "moving_duration_s",
          type: "number",
          required: false,
          presentable: false,
          unique: false,
          options: { min: 0, max: null, noDecimal: true },
        },
        {
          system: false,
          id: "fld_r_maxspeed",
          name: "max_speed_kmh",
          type: "number",
          required: false,
          presentable: false,
          unique: false,
          options: { min: 0, max: null, noDecimal: false },
        },
        {
          system: false,
          id: "fld_r_avgspeed",
          name: "avg_moving_speed_kmh",
          type: "number",
          required: false,
          presentable: false,
          unique: false,
          options: { min: 0, max: null, noDecimal: false },
        },
        {
          system: false,
          id: "fld_r_elev0001",
          name: "elevation_gain_m",
          type: "number",
          required: false,
          presentable: false,
          unique: false,
          options: { min: 0, max: null, noDecimal: false },
        },
        {
          system: false,
          id: "fld_r_title001",
          name: "title",
          type: "text",
          required: false,
          presentable: false,
          unique: false,
          options: { min: null, max: null, pattern: "" },
        },
        {
          system: false,
          id: "fld_r_notes001",
          name: "notes",
          type: "text",
          required: false,
          presentable: false,
          unique: false,
          options: { min: null, max: null, pattern: "" },
        },
        {
          system: false,
          id: "fld_r_points01",
          name: "points_json",
          type: "text",
          required: false,
          presentable: false,
          unique: false,
          options: { min: null, max: null, pattern: "" },
        },
        {
          system: false,
          id: "fld_r_updated1",
          name: "updated_at",
          type: "text",
          required: true,
          presentable: false,
          unique: false,
          options: { min: null, max: null, pattern: "" },
        },
        {
          system: false,
          id: "fld_r_deleted1",
          name: "deleted_at",
          type: "text",
          required: false,
          presentable: false,
          unique: false,
          options: { min: null, max: null, pattern: "" },
        },
      ],
      indexes: [
        "CREATE UNIQUE INDEX `idx_rides_client_id` ON `rides` (`client_id`)",
        "CREATE INDEX `idx_rides_updated_at` ON `rides` (`updated_at`)",
        "CREATE INDEX `idx_rides_started_at` ON `rides` (`started_at`)",
      ],
      // Same auth-only access as fillups.
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
    const collection = dao.findCollectionByNameOrId("rides");
    return dao.deleteCollection(collection);
  }
);
