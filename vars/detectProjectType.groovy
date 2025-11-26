#!/usr/bin/env groovy

def call(String projectPath = '.') {
    echo "Detecting project type for path: ${projectPath}"
    def projectInfo = detectProjectType(projectPath)

    echo "Project info detected: ${projectInfo}"
    echo "Project info type: ${projectInfo?.type}"
    echo "Project info port: ${projectInfo?.port}"

    if (projectInfo) {
        echo "Detected project type: ${projectInfo.type}"
        echo "Detected port: ${projectInfo.port}"

        if (!dockerfileExists(projectPath)) {
            def packageManager = detectPackageManager(projectPath)
            echo "Detected package manager: ${packageManager}"
            writeDockerfile(projectInfo.type, projectPath, packageManager)
        } else {
            echo "Dockerfile already exists at ${projectPath}/Dockerfile, skipping generation."
        }

        echo "Returning project info: ${projectInfo}"
        return projectInfo
    } else {
        error "Unable to detect the project type for ${projectPath}."
    }
}

def dockerfileExists(String projectPath) {
    return fileExists("${projectPath}/Dockerfile")
}

def detectProjectType(String projectPath) {
    echo "Checking for angular.json in ${projectPath}"
    if (fileExists("${projectPath}/angular.json")) {
        echo "Angular project detected through angular.json, setting port to 4200"
        return [type: 'angular', port: 4200]
    }
    else if (fileExists("${projectPath}/artisan")) {
        echo "Laravel project detected"
        return [type: 'laravel', port: 8000]
    }
    else if (fileExists("${projectPath}/package.json")) {
        def packageJson = readJSON file: "${projectPath}/package.json"
        echo "package.json contents: ${packageJson}"

        if (fileExists("${projectPath}/next.config.js") || fileExists("${projectPath}/next.config.mjs") || fileExists("${projectPath}/next.config.ts") || packageJson.dependencies?.next || packageJson.devDependencies?.next) {
            echo "Next.js dependencies or config found - starting standalone mode configuration"
            try {
                writeNextEnsureStandaloneMode(projectPath)
                echo "Standalone mode configuration completed successfully"
            } catch (Exception e) {
                echo "Error during standalone mode configuration: ${e.message}"
                // Continue execution even if configuration fails
            }
            echo "Next.js project detected, setting port to 3000"
            return [type: 'nextjs', port: 3000]
        } else if (packageJson.dependencies?.react || packageJson.devDependencies?.react) {
            if (fileExists("${projectPath}/vite.config.js") || fileExists("${projectPath}/vite.config.mjs") || fileExists("${projectPath}/vite.config.ts") || packageJson.dependencies?.vite || packageJson.devDependencies?.vite) {
                echo "React Vite project detected, setting port to 80"
                return [type: 'vite-react', port: 80]
            } else {
                echo "React project detected, setting port to 80"
                return [type: 'react', port: 80]
            } 
        }
        else if (packageJson.dependencies?.nuxt || packageJson.devDependencies?.nuxt) {
            echo "Nuxt.js project detected, setting port to 3000"
            return [type: 'nuxt', port: 3000]
        }else if (packageJson.dependencies?.vue || packageJson.devDependencies?.vue) {
            echo "Vue.js project detected, setting port to 8080"
            return [type: 'vuejs', port: 80]
        } else if (packageJson.dependencies?.angular || packageJson.devDependencies?.angular) {
            echo "Angular project detected, setting port to 4200"
            return [type: 'angular', port: 4200]
        }  else if (packageJson.dependencies?.svelte || packageJson.devDependencies?.svelte) {
            echo "Svelte project detected, setting port to 5000"
            return [type: 'svelte', port: 5000]
        } else if (packageJson.dependencies?.express || packageJson.devDependencies?.express) {
            echo "Express project detected, setting port to 3000"
            return [type: 'express', port: 3000]
        } else if (packageJson.dependencies?.nestjs || packageJson.devDependencies?.nestjs) {
            echo "NestJS project detected, setting port to 3000"
            return [type: 'nestjs', port: 3000]
        }
    }else if (fileExists("${projectPath}/index.html")) {
        echo "HTML project detected"
        return [type: 'html']
    } else if (fileExists("${projectPath}/index.php")) {
        echo "PHP project detected"
        return [type: 'php']
    } 

    //Detecting Backend Projects
    else if (fileExists("${projectPath}/pom.xml")) {
        echo "Spring Boot (Maven) project detected, setting port to 8080"
        return [type: 'springboot-maven', port: 8080]
    } else if (fileExists("${projectPath}/build.gradle") || fileExists("${projectPath}/build.gradle.kts")) {
        echo "Spring Boot (Gradle) project detected, setting port to 8080"
        return [type: 'springboot-gradle', port: 8080]
    } else if (fileExists("${projectPath}/pubspec.yaml")) {
        echo "Flutter project detected, setting port to 8080"
        return [type: 'flutter', port: 8080]
    }

    echo "No recognized project type detected in ${projectPath}"
    return null
}

def detectPackageManager(String projectPath) {
    if (fileExists("${projectPath}/pnpm-lock.yaml")) {
        return 'pnpm'
    } else if (fileExists("${projectPath}/yarn.lock")) {
        return 'yarn'
    } else if (fileExists("${projectPath}/package-lock.json")) {
        return 'npm'
    } else if (fileExists("${projectPath}/bun.lockb")) {
        return 'bun'
    }
    return 'npm'
}

def writeDockerfile(String projectType, String projectPath, String packageManager) {
    try {
        def dockerfileContent = libraryResource "dockerfileTemplates/Dockerfile-${projectType}"
        dockerfileContent = dockerfileContent.replaceAll("\\{\\{packageManager\\}\\}", packageManager)
        writeFile file: "${projectPath}/Dockerfile", text: dockerfileContent
        echo "2written for ${projectType} project at ${projectPath}/Dockerfile"
    } catch (Exception e) {
        error "Failed to write Dockerfile for ${projectType} project: ${e.message}"
    }
}


def writeNextEnsureStandaloneMode(String projectPath) {
    try {
        def scriptContent = libraryResource "scripts/ensure-next-standalone-mode.sh"
        def scriptPath = "${projectPath}/ensure-next-standalone-mode.sh"
        writeFile file: scriptPath, text: scriptContent
        echo "Script written for Next.js standalone mode at ${scriptPath}"
        
        // Make the script executable
        sh """
            chmod +x ${scriptPath}
            cd ${projectPath}
            ./ensure-next-standalone-mode.sh
        """
        
        echo "Next.js standalone mode configured successfully"
    } catch (Exception e) {
        error "Failed to write Next.js ensure standalone mode script: ${e.message}"
    }
}