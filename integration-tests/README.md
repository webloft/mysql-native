Integration Tests for MySQL Native
==================================

This sub-project is intended for proving the functionality of the project against a database instance.

See the instructions in the [main README](../README.md#developers---how-to-run-the-test-suite) on how to use this subpackage.

## Docker image

A docker-compose.yml is supplied for convenience when testing locally. It's preconfigured to use the same username/password that is used by default.

To run tests on your machine, presuming docker is installed, simply run:

```
$ docker-compose up --detach
```

Once you are finished, tear down the docker instance

```
$ docker-compose down
```
