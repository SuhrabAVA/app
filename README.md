# sheet_clone

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Lab: Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Cookbook: Useful Flutter samples](https://docs.flutter.dev/cookbook)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

## Order stage queue source of truth

The factual technological queue for an order is resolved through
`OrderQueueService`. The source priority is:

1. the saved queue on the order;
2. normalized production plan rows (`prod_plans` / `prod_plan_stages`);
3. legacy `production_plans.stages` JSON;
4. the stage template only as a fallback for old orders without a saved queue.

`stageTemplateId` is no longer a source of truth for the actual order queue. It
is retained as UI/editing metadata and as a legacy fallback key only when no
saved queue or plan rows exist.
