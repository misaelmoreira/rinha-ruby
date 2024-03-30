## Teste de Server Async I/O
Inspirado no server no Tonico do LeandronSP -> https://github.com/leandronsp/tonico

## Requisitos
* [Docker](https://docs.docker.com/get-docker/)
* [Gatling](https://gatling.io/open-source/), a performance testing tool
* Make (optional)

## Stack
* 2 Ruby 3.1 +YJIT apps
* 1 PostgreSQL
* 1 NGINX

## Uso

Rodando o bundle do ruby:

```bash
$ docker compose run ruby bundle
```

Rodando a api:

```bash
$ docker compose up 
```

Usando o wrk -> validando o server:

```bash
$ wrk -d 3s --latency http://localhost:9999/clientes/1/extrato
```

Testando o app:

```bash
$ curl -v localhost:9999/clientes/1/extrato
```

Realizando um post:

```bash
$ curl -X POST -H 'Content-Type: application/json' -d '{"valor": 100, "tipo": "c", "descricao": "blah"}' localhost:9999/clientes/1/transacoes
```

## Teste

Subindo apenas uma config docker compose:

```bash
$ docker compose up postgres
```