# EKS-D-Xpress Documentation Index

This file serves as a knowledge base index for AI assistants working with the EKS-D-Xpress codebase. It provides metadata and navigation guidance for the comprehensive documentation system.

## Quick Navigation for AI Assistants

### Primary Context File
- **`AGENTS.md`** (root directory): Start here for codebase navigation and context

### Detailed Documentation Files
- **`architecture.md`**: System architecture, deployment patterns, and component layers
- **`components.md`**: Detailed component breakdown with installation sequences
- **`interfaces.md`**: API integrations, Kubernetes interfaces, and external services
- **`data_models.md`**: Configuration structures, version matrices, and data formats
- **`workflows.md`**: End-to-end processes, error handling, and operational procedures
- **`dependencies.md`**: AWS service requirements, software dependencies, and compatibility

## How to Use This Documentation

### For Codebase Questions
1. **Navigation & Structure**: Consult `AGENTS.md` for directory layout and key entry points
2. **Technical Architecture**: Use `architecture.md` for system design and patterns
3. **Component Details**: Reference `components.md` for specific component information
4. **Integration Points**: Check `interfaces.md` for API and service integrations

### For Development Tasks
1. **Setup & Dependencies**: Start with `dependencies.md` for requirements
2. **Process Understanding**: Use `workflows.md` for step-by-step procedures
3. **Configuration**: Reference `data_models.md` for structure and formats
4. **Component Modification**: Combine `components.md` and `interfaces.md`

### For Troubleshooting
1. **Architecture Overview**: Use `architecture.md` to understand system layers
2. **Component Relationships**: Check `components.md` for dependency information
3. **Error Handling**: Reference `workflows.md` for recovery procedures
4. **Integration Issues**: Use `interfaces.md` for external service problems

## File Summaries

### `AGENTS.md` (Root Directory)
**Purpose**: Primary context file for AI coding assistants
**Content**: Repository navigation, key entry points, development patterns, and workflow deviations
**Use When**: Starting work on the codebase, understanding project structure, or need quick orientation

### `architecture.md`
**Purpose**: High-level system design and architectural patterns
**Content**: System layers, deployment patterns, security architecture, component relationships
**Use When**: Understanding system design, architectural decisions, or integration approaches

### `components.md`  
**Purpose**: Detailed breakdown of system components and their responsibilities
**Content**: AMI builder, EKS-D setup scripts, node pools, monitoring, progress tracking
**Use When**: Working with specific components, understanding installation sequences, or modifying functionality

### `interfaces.md`
**Purpose**: External integrations, APIs, and service interfaces  
**Content**: AWS service integrations, Kubernetes APIs, authentication, networking, storage
**Use When**: Integrating with external services, troubleshooting connectivity, or understanding authentication

### `data_models.md`
**Purpose**: Configuration structures, data formats, and version management
**Content**: Component versions, CDK/CloudFormation structures, Kubernetes resources, progress tracking
**Use When**: Working with configuration, understanding data formats, or managing versions

### `workflows.md`
**Purpose**: End-to-end processes and operational procedures
**Content**: Deployment workflows, installation sequences, error handling, monitoring processes
**Use When**: Understanding complete processes, implementing error handling, or operational procedures

### `dependencies.md`
**Purpose**: External dependencies and requirements
**Content**: AWS services, software requirements, version compatibility, network dependencies  
**Use When**: Setting up environment, troubleshooting dependencies, or planning deployments

### `review_notes.md`
**Purpose**: Documentation quality assessment and improvement recommendations
**Content**: Consistency checks, completeness analysis, identified gaps, improvement suggestions
**Use When**: Improving documentation quality or identifying areas needing enhancement

## Metadata Tags

### Architecture & Design
- `#architecture` - System design and patterns
- `#components` - Individual component details
- `#security` - Security patterns and authentication
- `#networking` - Network configuration and CNI

### Operations & Deployment  
- `#deployment` - Deployment processes and workflows
- `#installation` - Installation sequences and scripts
- `#monitoring` - Observability and metrics
- `#troubleshooting` - Error handling and recovery

### Development & Configuration
- `#configuration` - Settings and customization
- `#dependencies` - Requirements and compatibility
- `#integration` - External service connections
- `#versioning` - Component version management

## Cross-References

### Related Sections
- **Architecture ↔ Components**: System design connects to component implementation
- **Workflows ↔ Components**: Process flows reference specific component scripts  
- **Interfaces ↔ Dependencies**: External integrations require specific dependencies
- **Data Models ↔ Configuration**: Data structures define configuration formats

### Common Integration Points
- **AMI Building**: References architecture.md, components.md, workflows.md
- **EKS-D Installation**: Spans components.md, workflows.md, data_models.md
- **AWS Integration**: Covers interfaces.md, dependencies.md, architecture.md  
- **Monitoring Setup**: Involves components.md, workflows.md, interfaces.md

This index provides sufficient metadata for AI assistants to navigate the documentation effectively and find relevant information for any EKS-D-Xpress development or operational task.
