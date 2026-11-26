CREATE TABLE "llm_usage" (
	"owner_id" text NOT NULL,
	"month" text NOT NULL,
	"calls" integer DEFAULT 0 NOT NULL,
	CONSTRAINT "llm_usage_owner_id_month_pk" PRIMARY KEY("owner_id","month")
);
--> statement-breakpoint
CREATE TABLE "note_segments" (
	"note_id" uuid NOT NULL,
	"index" integer NOT NULL,
	"duration_ms" integer NOT NULL,
	"uploaded_at" timestamp with time zone,
	CONSTRAINT "note_segments_note_id_index_pk" PRIMARY KEY("note_id","index")
);
--> statement-breakpoint
CREATE TABLE "notes" (
	"id" uuid PRIMARY KEY NOT NULL,
	"owner_id" text NOT NULL,
	"title" text NOT NULL,
	"locale" text NOT NULL,
	"duration_ms" integer DEFAULT 0 NOT NULL,
	"transcript" jsonb DEFAULT '[]'::jsonb NOT NULL,
	"speakers" jsonb DEFAULT '[]'::jsonb NOT NULL,
	"transcript_hash" text,
	"extraction" jsonb DEFAULT '{"chains":[]}'::jsonb NOT NULL,
	"extraction_version" integer DEFAULT 0 NOT NULL,
	"extracted_hash" text,
	"extract_count" integer DEFAULT 0 NOT NULL,
	"imported" jsonb DEFAULT '[]'::jsonb NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "note_segments" ADD CONSTRAINT "note_segments_note_id_notes_id_fk" FOREIGN KEY ("note_id") REFERENCES "public"."notes"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "notes_owner_idx" ON "notes" USING btree ("owner_id","created_at" DESC NULLS LAST);