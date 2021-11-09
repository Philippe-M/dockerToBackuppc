Dans un environnement de production il est important de réaliser des sauvegardes (en mode dev aussi d’ailleurs). Docker nous apporte une très grande souplesse et facilement nous pouvons proposer différents services. Mais comment faire pour sauvegarder le contenue de ces services ? Pour illustrer cette exemple, j’utiliserais Glpi.

Je part du principe que vous maîtrisez BackupPC, Docker, Docker-compose, Glpi et Traefik. Chaque brique est opérationnel et je détaillerais uniquement ce qui est en lien avec le script.

## Pourquoi le contenue ?

Nos container mènes leurs petites vies, dans notre exemple Glpi est utilisé pour maintenir l’inventaire du parc informatique (matériel et financier) avec le plugin Fusion Inventory et aussi pour gérer les tickets du support. Vous vous imaginez bien que toutes ces données change en permanence et qu’il est important de pouvoir les restaurer en cas de crash.

Par défaut Docker propose une solution basique pour « sauvegarder » un container : docker export. Au préalable cela demande de faire un commit et espérer qu’aucun enregistrement sera fait dans la base de données lorsque vous exécuterez l’export. Donc autant dire que c’est peine perdu et de plus un container seul ne sert quasiment à rien sans son Dockerfile ou docker-compose.yml (voir les deux). Autre problème : la volumétrie. A chaque export c’est l’intégralité du container que vous copiez dans un fichier « tar » et il devient difficile de l’intégrer dans le système de déduplication de BackupPC.

## La genèse

Pour notre exemple nous utiliserons deux serveurs :

- svbackup : serveur de sauvegarde où sera installé et paramétré BackupPC;</li>
- svdocker : serveur docker où sera installé docker, docker-compose, Traefik, mysqldump, rsync.</li>

La communication entre ces serveurs ce fera par ssh avec échange de clés pour ne plus avoir besoin de saisir les mots de passe.

## Au début il y avait docker-compose

Pour construire mes container j’utilise docker-compose. Dans BackupPC je créé un job qui sera chargé de copier uniquement les fichiers de configurations et créations de mes containers. Sur svdocker nous les stockerons dans le dossier /home de l’utilisateur backuppc.

## Naquirent les containers

Pour Glpi j’utilise deux containers, un premier pour la partie web et un autre pour la partie mysql.

docker-compose.yml

```
version: '3.3'
services:
  glpi_mysql:
    image: mysql:latest
    container_name: glpi_mysql
    hostname: glpi_mysql
    command: --default-authentication-plugin=mysql_native_password
    env_file:
      - ./mysql.env
    volumes:
      - "/var/lib/mysql/glpi:/var/lib/mysql"
    networks:
      - traefik
    restart: always

  # use a Dockerfile
  glpi_www:
    depends_on:
      - glpi_mysql
    build: .
    container_name: glpi_www
    volumes:
      - "/var/www/hml:/var/www/html"
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.glpi_www.rule=Host(`glpi.mondomaine.fr`)"
      - "traefik.http.routers.glpi_www.entrypoints=websecure"
      - "traefik.http.routers.glpi_www.tls.certresolver=le"
    networks:
      - traefik
    restart: always;

networks:
  traefik:
    external: true
```

Pour le container glpi_www j’utilise un Dockerfile qui se charge de télécharger l’image php:apache-7.3 et installer les dépendances nécessaires pour faire tourner Glpi. En l’état rien de bien exceptionnel. Vous pouvez voir que j’utilise Traefik pour accéder simplement au container glpi_www. En l’état tout devrait marcher.

Pour permettre à BackupPC de récupérer les informations nécessaire à la sauvegarde nous allons utiliser les labels.

docker-compose.yml

```
version: '3.3'
services:
  glpi_mysql:
    image: mysql:latest
    container_name: glpi_mysql
    hostname: glpi_mysql
    command: --default-authentication-plugin=mysql_native_password
    env_file:
      - ./mysql.env
    volumes:
      - "/var/lib/mysql/glpi:/var/lib/mysql"
    networks:
      - traefik
    restart: always

  # use a Dockerfile
  glpi_www:
    depends_on:
      - glpi_mysql
    build: .
    container_name: glpi_www
    volumes:
      - "/var/www/html:/var/www/html"
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.glpi_www.rule=Host(`glpi.mondomaine.fr`)"
      - "traefik.http.routers.glpi_www.entrypoints=websecure"
      - "traefik.http.routers.glpi_www.tls.certresolver=le"
      - "backuppc.active=true"
      - "backuppc.services=volume,"
      - "backuppc.volume.path=/var/www/html"
    networks:
      - traefik
    restart: always

networks:
  traefik:
    external: true
```

J’ai ajouté trois labels :

- backuppc.active = true : active ou désactive la sauvegarde [true|false];</li>
- backuppc.services = volume, : type de services à sauvegarde. Pour le moment il est possible de sauvegarder les fichiers et la base de données Mysql. <strong>La virgule à la fin est obligatoire;</strong></li>
- backuppc.volume.path = /var/www/html : répertoire dans le container à sauvegarder.</li>

Télécharger le fichier backup-container.sh sur le serveur svdocker dans le dossier « home » de l’utilisateur backuppc. Sur le serveur svbackup connectez-vous à l’interface de BackupPC pour créer une machine nommé « docker-glpi_www ». Ce nom vous permettra de retrouver rapidement votre sauvegarde dans la liste des machines enregistré. Il y a une subtilité car ce même nom est utilisé par BackupPC pour contrôler si la machine est accessible sur le réseau. Il va falloir contourner le problème en modifiant les champs ClientNameAlias, PingCmd en remplaçant la variable « $host » par le nom DNS de votre serveur Docker, ici : svdocker

![dockerToBackuppc](https://philippe-maladjian.fr/data/medias/Informatiques/backuppc/dockerToBackuppc/docker_backuppc_01.jpg)

Pour lancer la copie des fichiers du container vers l’hôte j’utilise la fonction « DumpPreUserCmd », pour faire simple cela permet de lancer un programme sur l’hôte avant que BackupPC rapatrie les fichiers. Ici nous allons lancer le script backup-container.sh.

![dockerToBackuppc](https://philippe-maladjian.fr/data/medias/Informatiques/backuppc/dockerToBackuppc/docker_backuppc_02.jpg)

La commande :

`$sshPath -x -l backuppc -i /home/backuppc/.ssh/id_rsa svdocker sudo /home/backuppc/./backup-container.sh -d glpi_www`

Explication :

- $sshPath -x -l backuppc -i /home/backuppc/.ssh/id_rsa svdocker : se connecte en ssh à svdocker avec l’utilisateur backuppc et la clé associée;</li>
- sudo /home/backuppc/./backup-container.sh -d glpi_www : lance le script backup-container.sh avec en paramètre le nom du container à sauvegarder. Par défaut les fichiers du container sont copiés dans le dossier /export/glpi_www de l’hôte donc il faut penser à indiquer à BackupPC où aller chercher les fichiers.</li>


![dockerToBackuppc](https://philippe-maladjian.fr/data/medias/Informatiques/backuppc/dockerToBackuppc/docker_backuppc_03.jpg)

Il reste une dernière étape avant de lancer notre première sauvegarde. Le script copie les fichiers du container vers l’hôte dans le dossier /export/glpi_www, il est donc nécessaire de purger ce dossier après chaque sauvegarde. J’utilise cette fois l’option « DumpPostUserCmd »

![dockerToBackuppc](https://philippe-maladjian.fr/data/medias/Informatiques/backuppc/dockerToBackuppc/docker_backuppc_04.jpg)

Avec la commande

`$sshPath -x -l backuppc -i /home/backuppc/.ssh/id_rsa svdocker sudo /home/backuppc/./backup-container.sh -d glpi_www -r`

Le fonctionnement est le même que pour la commande de « predump ». A la différence que je passe le paramètre « -r » au script backup-container.sh pour effacer le contenu du dossier « /export/glpi_www ».

Vous pouvez enregistrer le jobs et faire vos premiers essais. Si tout ce passe bien vous pouvez suivre en live sur svdocker le répertoire « /export/glpi_www » se remplir, une fois fini BackupPC va les copier avec rsync et lancer la commande de purge du répertoire « /export/glpi_www ».

## Et ma base ?

Avec Mysql l’idée est la même. Nous allons éditer le fichier docker-compose.yml de notre ensemble pour ajouter les labels nécessaire à mysql.

```
version: '3.3'
services:
  glpi_mysql:
    image: mysql:latest
    container_name: glpi_mysql
    hostname: glpi_mysql
    command: --default-authentication-plugin=mysql_native_password
    env_file:
      - ./mysql.env
    volumes:
      - "/var/lib/mysql/glpi:/var/lib/mysql"
    labels:
      - "traefik.enable=true"
      - "traefik.tcp.routers.glpi_mysql.rule=HostSNI(`*`)"
      - "traefik.tcp.services.glpi_mysql.loadBalancer.server.port=3306"
      - "traefik.tcp.routers.glpi_mysql.entrypoints=mysql"
      - "backuppc.active=true"
      - "backuppc.services=mysql,"
    networks:
      - traefik
    restart: always

[…]
```

Cette fois backuppc.services contient « mysql » comme valeur mais ce n’est pas plus important et délicat. Pour que cela marche correctement vous devez activer la connexion par TCP à Traefik de façon à pouvoir depuis l’hôte lancer mysqldump. Il aurait été possible de lancer mysqldump à l’intérieur du container mais cela imposait d'installer dans tout les container « mysqldump » avec toutes les dépendances.
Sur le serveur svbackup créer un job docker-glpi_mysql en reprenant les mêmes valeur que pour le précédent job à la différence des paramètres à passer au script backup_container :

`$sshPath -x -l backuppc -i /home/backuppc/.ssh/id_rsa svdocker sudo /home/backuppc/./backup-container.sh -d glpi_mysql -u dbuser -p dbpassword -h glpi_mysql.mondomaine.fr -n glpi_prod -c`

- $sshPath -x -l backuppc -i /home/backuppc/.ssh/id_rsa svdocker : connexion à svdocker;</li>
- sudo /home/backuppc/./backup-container.sh -d glpi_mysql -u dbuser -p dbpassword -h glpi_mysql.mondomaine.fr -n glpi_prod -c : lance le script;
  -d : nom du container;</li>
  -h : nom dns par lequel le container est joignable : dans notre exemple c’est « glpi_mysql.mondomaine.fr »;</li>
  -n : nom de la base de données;</li>
  -u : nom d’utilisateur mysql;</li>
  -p : mot de passe mysql;</li>
  -c : si ajouté compresse le fichier sql.

Il ne vous reste plus qu’à faire un test de sauvegarde.

## Tout en un

Si votre container est à la fois le serveur web et le serveur mysql il va falloir modifier votre docker-compose.yml

```
version: '3.3' services:
  glpi:
    image: mysql:latest
    container_name: glpi
    hostname: glpi
    command: --default-authentication-plugin=mysql_native_password
    env_file:
      - ./mysql.env
    volumes:
      - "/var/lib/mysql/glpi:/var/lib/mysql"
      - "/var/www/html:/var/www/html"
    labels:
      - "traefik.enable=true"
      - "traefik.tcp.routers.glpi_mysql.rule=HostSNI(`*`)"
      - "traefik.tcp.services.glpi_mysql.loadBalancer.server.port=3306"
      - "traefik.tcp.routers.glpi_mysql.entrypoints=mysql"
      - "backuppc.active=true"
      - "backuppc.services=mysql,volume"
      - "backuppc.volume.path=/var/www/html"
    networks:
      - traefik
    restart: always
```

La commande de PreDump reste la même, il faut juste adapté le nom du container :

`$sshPath -x -l backuppc -i /home/backuppc/.ssh/id_rsa svdocker sudo /home/backuppc/./backup-container.sh -d glpi -u dbuser -p dbpassword -c -n glpi_prod`

