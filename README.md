# ScriptScanGithubJavaAngular

Ce script permet de scanner un repository git en permettant 
l'analyse :

- pour du code java du fichier pom.xml (maven) à la recherche
de la version de java utiliser de springboot
</br>
Il va rechercher dans la branch par default du projet le fichier pom.xml 
et si l'architecture mise en place est un second pom.xml un repertoire app
</br>
- pour du code front angular ou vue o react, il va parser le fichier package-lock.json à la recherche des versions 
utilisées
