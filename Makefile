.PHONY: up down logs psql reset

up:
	docker compose up -d
	@echo "Waiting for Postgres to become healthy..."
	@until [ "$$(docker inspect -f '{{.State.Health.Status}}' pg_clickhouse_poc 2>/dev/null)" = "healthy" ]; do \
		sleep 1; \
	done
	@echo "Ready. Try: make psql"

down:
	docker compose down

reset:
	docker compose down -v
	$(MAKE) up

logs:
	docker compose logs -f postgres

psql:
	docker compose exec postgres psql -U $${POSTGRES_USER:-postgres} -d $${POSTGRES_DB:-tinybird_bridge}
