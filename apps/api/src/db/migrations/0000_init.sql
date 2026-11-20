CREATE TABLE "prerequisites" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"task_id" uuid NOT NULL,
	"position" integer NOT NULL,
	"action" text NOT NULL,
	"urgency" text NOT NULL,
	"done_at" timestamp with time zone,
	CONSTRAINT "prerequisites_urgency" CHECK ("prerequisites"."urgency" in ('early', 'before', 'onsite'))
);
--> statement-breakpoint
CREATE TABLE "projects" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"owner_id" text NOT NULL,
	"name" text NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "tasks" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"project_id" uuid NOT NULL,
	"parent_id" uuid,
	"position" integer NOT NULL,
	"name" text NOT NULL,
	"short" text NOT NULL,
	"place" text DEFAULT '' NOT NULL,
	"lat" double precision,
	"lng" double precision,
	"completed_at" timestamp with time zone,
	"children_version" integer DEFAULT 0 NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "tasks_geo_pair" CHECK (("tasks"."lat" is null) = ("tasks"."lng" is null))
);
--> statement-breakpoint
ALTER TABLE "prerequisites" ADD CONSTRAINT "prerequisites_task_id_tasks_id_fk" FOREIGN KEY ("task_id") REFERENCES "public"."tasks"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "tasks" ADD CONSTRAINT "tasks_project_id_projects_id_fk" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "tasks" ADD CONSTRAINT "tasks_parent_id_tasks_id_fk" FOREIGN KEY ("parent_id") REFERENCES "public"."tasks"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "prerequisites_task_idx" ON "prerequisites" USING btree ("task_id","position");--> statement-breakpoint
CREATE INDEX "projects_owner_idx" ON "projects" USING btree ("owner_id","created_at");--> statement-breakpoint
CREATE INDEX "tasks_parent_idx" ON "tasks" USING btree ("parent_id","position");--> statement-breakpoint
CREATE INDEX "tasks_project_idx" ON "tasks" USING btree ("project_id");--> statement-breakpoint
CREATE UNIQUE INDEX "tasks_one_root_per_project" ON "tasks" USING btree ("project_id") WHERE "tasks"."parent_id" is null;