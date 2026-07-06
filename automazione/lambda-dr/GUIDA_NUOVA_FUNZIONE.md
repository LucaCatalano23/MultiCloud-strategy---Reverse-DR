# Guida: aggiungere una nuova funzione Lambda on-prem

Questa guida spiega come aggiungere una nuova funzione alla piattaforma Lambda DR su Kubernetes senza spegnere l'adapter e senza modificare le funzioni gia' in esecuzione.

## Obiettivo

Alla fine avrai:

- un nuovo runtime Kubernetes isolato;
- un nuovo Service interno chiamato `lambda-<nome-funzione>`;
- una funzione invocabile tramite:

```text
http://localhost:18088/functions/<nome-funzione>/<path-applicativo>
```

Esempio:

```text
http://localhost:18088/functions/invoices/invoices/2026
```

## Prerequisiti

Verifica che la piattaforma base sia attiva:

```powershell
kubectl -n lambda-dr get pods
```

Devi vedere almeno:

```text
event-adapter   Running
lambda-orders   Running
lambda-payments Running
```

Verifica anche che l'immagine runtime sia disponibile nel cluster:

```powershell
kubectl -n lambda-dr get deployment lambda-orders -o jsonpath="{.spec.template.spec.containers[0].image}"
```

Output atteso:

```text
reverse-dr/lambda-runtime:python3.11
```

## Regole di naming

Scegli un nome funzione semplice, solo minuscole, numeri e trattini.

Valido:

```text
invoices
customer-report
batch-2026
```

Non valido:

```text
Invoices
customer_report
my function
```

In questa guida useremo:

```text
invoices
```

La convenzione e':

```text
funzione: invoices
Deployment: lambda-invoices
Service: lambda-invoices
ConfigMap codice: lambda-invoices-code
```

Questa convenzione e' importante perche' l'adapter risolve automaticamente:

```text
lambda-{function_name}.lambda-dr.svc.cluster.local:8080
```

## 1. Crea il file manifest della funzione

Crea un nuovo file:

```text
automazione/lambda-dr/kubernetes/sample-invoices-function.yaml
```

Contenuto:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: lambda-invoices-code
  namespace: lambda-dr
  labels:
    app.kubernetes.io/name: lambda-invoices
    app.kubernetes.io/part-of: reverse-dr-lambda-platform
data:
  app.py: |
    from __future__ import annotations

    import json
    from typing import Any


    def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
        invoice_id = event.get("pathParameters", {}).get("proxy", "")

        return {
            "statusCode": 200,
            "headers": {"content-type": "application/json"},
            "body": json.dumps(
                {
                    "function": "invoices",
                    "method": event.get("httpMethod"),
                    "path": event.get("path"),
                    "invoicePath": invoice_id,
                    "query": event.get("queryStringParameters"),
                    "requestId": event.get("requestContext", {}).get("requestId"),
                }
            ),
        }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: lambda-invoices
  namespace: lambda-dr
  labels:
    app.kubernetes.io/name: lambda-invoices
    app.kubernetes.io/part-of: reverse-dr-lambda-platform
    lambda-dr/function-name: invoices
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: lambda-invoices
  template:
    metadata:
      labels:
        app.kubernetes.io/name: lambda-invoices
        app.kubernetes.io/part-of: reverse-dr-lambda-platform
        lambda-dr/function-name: invoices
        lambda-dr/runtime: "true"
    spec:
      automountServiceAccountToken: false
      securityContext:
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: runtime
          image: reverse-dr/lambda-runtime:python3.11
          imagePullPolicy: IfNotPresent
          ports:
            - name: rie
              containerPort: 8080
          env:
            - name: AWS_REGION
              value: eu-west-1
            - name: AWS_DEFAULT_REGION
              value: eu-west-1
            - name: AWS_LAMBDA_FUNCTION_NAME
              value: invoices
            - name: AWS_LAMBDA_FUNCTION_MEMORY_SIZE
              value: "512"
            - name: AWS_LAMBDA_FUNCTION_VERSION
              value: "$LATEST"
          readinessProbe:
            tcpSocket:
              port: rie
            periodSeconds: 5
          livenessProbe:
            tcpSocket:
              port: rie
            initialDelaySeconds: 10
            periodSeconds: 20
          resources:
            requests:
              cpu: 50m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 512Mi
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
            readOnlyRootFilesystem: true
          volumeMounts:
            - name: function-code
              mountPath: /var/task
              readOnly: true
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: function-code
          configMap:
            name: lambda-invoices-code
            defaultMode: 0444
        - name: tmp
          emptyDir:
            medium: Memory
            sizeLimit: 512Mi
---
apiVersion: v1
kind: Service
metadata:
  name: lambda-invoices
  namespace: lambda-dr
  labels:
    app.kubernetes.io/name: lambda-invoices
    app.kubernetes.io/part-of: reverse-dr-lambda-platform
    lambda-dr/function-name: invoices
spec:
  selector:
    app.kubernetes.io/name: lambda-invoices
  ports:
    - name: rie
      port: 8080
      targetPort: rie
```

## 2. Applica la funzione al cluster

Esegui:

```powershell
kubectl apply -f automazione\lambda-dr\kubernetes\sample-invoices-function.yaml
```

Perche': questo crea solo la nuova funzione `invoices`. Non riavvia `event-adapter`, `orders` o `payments`.

## 3. Verifica che il runtime sia partito

```powershell
kubectl -n lambda-dr rollout status deployment/lambda-invoices
kubectl -n lambda-dr get pods
```

Output atteso:

```text
lambda-invoices-...   1/1   Running
```

Verifica anche il Service:

```powershell
kubectl -n lambda-dr get svc lambda-invoices
kubectl -n lambda-dr get endpoints lambda-invoices
```

Devi vedere un endpoint sulla porta `8080`.

## 4. Esponi l'adapter in locale

Se non hai gia' un port-forward aperto:

```powershell
kubectl -n lambda-dr port-forward svc/event-adapter 18088:8080
```

Lascia questo terminale aperto.

## 5. Invoca la nuova funzione

In un altro terminale:

```powershell
Invoke-RestMethod -Method Post -Uri "http://localhost:18088/functions/invoices/invoices/2026?format=summary" -Body '{"year":2026}' -ContentType "application/json"
```

Risposta attesa:

```text
function    : invoices
method      : POST
path        : /invoices/2026
invoicePath : invoices/2026
query       : @{format=summary}
requestId   : ...
```

## 6. Controlla i log

Log dell'adapter:

```powershell
kubectl -n lambda-dr logs deployment/event-adapter --tail=50
```

Log della funzione:

```powershell
kubectl -n lambda-dr logs deployment/lambda-invoices --tail=50
```

Nel runtime Lambda dovresti vedere righe simili:

```text
START RequestId: ...
END RequestId: ...
REPORT RequestId: ...
```

## 7. Aggiornare il codice della funzione

Per modificare la funzione `invoices`, aggiorna **solo** il blocco `data.app.py` dentro la ConfigMap `lambda-invoices-code` nel file:

```text
automazione/lambda-dr/kubernetes/sample-invoices-function.yaml
```

Non devi modificare:

```text
automazione/lambda-dr/sample-lambda/app.py
```

Quel file e' solo il codice demo copiato nell'immagine base per il test Docker Compose. In Kubernetes, ogni funzione monta il proprio codice sopra `/var/task` tramite la propria ConfigMap, quindi il codice della ConfigMap nasconde quello contenuto nell'immagine.

Nel caso di `invoices`, il codice effettivo e' questo blocco:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: lambda-invoices-code
data:
  app.py: |
    def handler(event, context):
        ...
```

Poi riapplica:

```powershell
kubectl apply -f automazione\lambda-dr\kubernetes\sample-invoices-function.yaml
```

Poi riavvia solo quella funzione:

```powershell
kubectl -n lambda-dr rollout restart deployment/lambda-invoices
kubectl -n lambda-dr rollout status deployment/lambda-invoices
```

Perche': il codice montato da ConfigMap viene letto all'avvio del pod. Riavvii solo `lambda-invoices`, non l'intera piattaforma.

Le altre funzioni non vengono toccate:

```text
lambda-orders   usa lambda-orders-code
lambda-payments usa lambda-payments-code
lambda-reports  usa lambda-reports-code
lambda-invoices usa lambda-invoices-code
```

Quindi modificare `lambda-invoices-code` non cambia il codice di `orders`, `payments` o `reports`.

## 8. Rimuovere una funzione

Per eliminare solo la funzione `invoices`:

```powershell
kubectl delete -f automazione\lambda-dr\kubernetes\sample-invoices-function.yaml
```

L'adapter e le altre funzioni restano attive.

## Checklist rapida

Per aggiungere una funzione devi sempre creare:

- `ConfigMap` con `app.py`;
- `Deployment` chiamato `lambda-<nome>`;
- `Service` chiamato `lambda-<nome>`;
- label `lambda-dr/runtime: "true"` sul pod della funzione;
- mount del codice in `/var/task`;
- mount writable di `/tmp`;
- porta RIE `8080`.

## Nota production

La ConfigMap e' comoda per la demo e per la tesi, ma non e' il modello migliore per produzione.

In produzione il codice dovrebbe arrivare da:

- artifact store;
- registry OCI;
- bucket S3-compatible;
- pipeline CI/CD;
- bundle firmato e verificato da init container.

Il modello architetturale resta lo stesso: l'utente aggiunge una nuova funzione, la piattaforma crea un nuovo runtime isolato, l'adapter rimane acceso.
