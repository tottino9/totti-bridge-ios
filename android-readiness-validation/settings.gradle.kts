pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google(); mavenCentral()
        maven {
            url = uri("https://maven.rokid.com/repository/maven-public/")
            content { includeGroup("com.rokid.cxr") }
        }
    }
}
rootProject.name = "TottiReadinessValidation"
include(":app")
