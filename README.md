# DriveEasy Backend

## Demarrage sans Docker Desktop

Prerequis : JDK 21, Maven 3.9+ et Internet au premier lancement.

Depuis ce dossier, lancer `start-demo.cmd`. Il demarre Eureka, Config Server, les trois services metier et API Gateway. Aucune fenetre Docker n'est necessaire. Zipkin est optionnel : lancer `start-zipkin.cmd` pour le demarrer avec Java (telechargement initial d'environ 129 MB).

Adresses : Eureka `http://localhost:8761`, Config Server `http://localhost:8889`, Gateway `http://localhost:8080`, Zipkin `http://localhost:9412` apres l'avoir lance.

Arret : lancer `stop-demo.cmd`. Les donnees metier sont en memoire et reviennent a l'etat initial au redemarrage.

## Architecture et ports

| Composant | Port | Role |
|---|---:|---|
| Eureka | 8761 | Registre des services |
| Config Server | 8889 | Configuration native depuis `config-repo/` (sans Git) |
| API Gateway | 8080 | Routage REST et CORS |
| vehicule-service | 8081 | Parc et disponibilite |
| client-service | 8082 | Dossiers clients et eligibilite |
| location-service | 8083 | Reservations, prix et retours |
| Zipkin | 9412 | Traces distribuees (version autonome, sans Docker) |

## Endpoints via Gateway

- Vehicules : `/api/vehicules`, `/api/vehicules/disponibles`, `/api/vehicules/{id}`
- Clients : `/api/clients`, `/api/clients/{id}`, `/api/clients/{id}/eligibilite`
- Locations : `/api/locations`, `/api/locations/simulation`, `/api/locations/statistiques`

`config-repo/` contient les fichiers YAML lus directement par Config Server. Git et Docker Desktop ne sont pas necessaires pour lancer la demo.
