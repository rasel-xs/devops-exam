# docker/

The build context is `scenario-b/app/`, so `.dockerignore` lives there
(`app/.dockerignore`) — Docker only reads the one at the root of the context.

```bash
cd scenario-b
docker build -f docker/Dockerfile       -t notes-api:multi app/
docker build -f docker/Dockerfile.naive -t notes-api:naive app/
docker images | grep notes-api
```
