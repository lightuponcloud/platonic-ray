**Contributing to Platonic Ray**

Thank you for your interest in contributing to Platonic Ray! We welcome contributions from the community, whether you're fixing bugs, adding features, improving documentation, or reporting issues. This guide outlines how you can get involved and help make Platonic Ray even better.

**How to Contribute**

**Reporting Bugs**

If you find a bug, please let us know so we can address it! To report a bug:

*   Check the [GitHub Issues](https://github.com/lightuponcloud/platonic-ray/issues) page to ensure the bug hasn’t already been reported.
    
*   Open a new issue with a clear title and description, including:
    
    *   A brief summary of the bug.
        
    *   Steps to reproduce the issue.
        
    *   Expected and actual behavior.
        
    *   Your environment (e.g., OS, Erlang version, Riak CS version).
        
    *   Any relevant logs or screenshots.
        
*   Use the "Bug" label when creating the issue.
    

**Suggesting Features**

Have an idea to improve Platonic Ray? We’d love to hear it! To suggest a feature:

*   Check the [GitHub Issues](https://github.com/lightuponcloud/platonic-ray/issues) to see if your idea has already been proposed.
    
*   Open a new issue with a descriptive title and include:
    
    *   A clear explanation of the feature and its use case.
        
    *   Any potential benefits for users (e.g., photographers, small businesses).
        
    *   Possible implementation details, if applicable.
        
*   Use the "Enhancement" label for feature requests.
    

**Contributing Code**

We welcome code contributions, from small fixes to new features. To contribute code:

*   Fork the repository and create a new branch for your changes (e.g., fix-thumbnail-bug or add-api-endpoint).
    
*   Ensure your code follows the style guidelines (#code-style) below.
    
*   Write clear commit messages (e.g., Fix watermark alignment in thumbnail generation).
    
*   Test your changes locally (see Development Setup (#development-setup)).
    
*   Submit a pull request (PR) following the Pull Request Guidelines (#pull-request-guidelines).
    

**Code Style**

*   Follow Erlang coding conventions (e.g., use meaningful variable names, avoid deep nesting).
    
*   Keep functions small and focused.
    
*   Include comments for complex logic.
    
*   Update relevant documentation (e.g., README.md, API.md) if your changes affect usage.
    
*   Ensure code is compatible with Erlang versions >= 23.
    

**Improving Documentation**

Documentation is critical for Platonic Ray’s usability. To contribute to documentation:

*   Fork the repository and create a branch (e.g., docs-update-readme).
    
*   Make changes to files in the doc/ directory, README.md, or other relevant files.
    
*   Ensure clarity, correct grammar, and proper Markdown formatting.
    
*   Submit a pull request with a description of your changes.

*   Send us link to Pull Request
    

Examples of documentation contributions:

*   Clarifying installation steps.
    
*   Adding examples for API usage.
    
*   Updating screenshots or architecture diagrams.
    
*   Fixing typos or outdated information.
    

**Development Setup**

To set up Platonic Ray for local development, follow these steps (see README.md for full details):

*   **Install Dependencies**:
    
    *   Erlang (>= 23, < 25)
        
    *   coreutils (/usr/bin/head, /bin/mktemp)
        
    *   imagemagick-6.q16, libmagickwand-dev
        
    *   Riak CS (see Riak CS Installation Manual (/doc/riak\_cs\_setup.md))
        
*   **Build the Project**:
    
*   sh
    

git clone https://github.com/USERNAME/platonic-ray.git

cd platonic-ray

wget https://s3.amazonaws.com/rebar3/rebar3

chmod +x rebar3

rebar3 clean

rebar3 compile

*   rebar3 release
    
*   **Configure**:
    
    *   Update include/storage.hrl, include/riak.hrl, and include/general.hrl as described in README.md.
        
    *   Temporarily disable authentication to add the first user.
        
    *   Run the project with make run.
        
*   **Test Changes**:
    
    *   Test file synchronization, API endpoints, or thumbnail generation locally.
        
    *   Verify compatibility with supported platforms (Windows, iOS, Android).
        

If you encounter issues, check the [GitHub Issues](https://github.com/lightuponcloud/platonic-ray/issues) or reach out (see Contact (#contact)).

**Pull Request Guidelines**

To ensure a smooth review process, please follow these guidelines when submitting a pull request:

*   Create a PR against the main branch from your feature or bugfix branch.
    
*   Include a clear title and description, explaining:
    
    *   What the PR does.
        
    *   Why it’s needed (reference related issues, e.g., #123).
        
    *   Any testing performed.
        
*   Ensure all code is tested and doesn’t break existing functionality.
    
*   Update documentation if your changes affect setup, usage, or APIs.
    
*   Be prepared to address feedback or make revisions during the review process.
    

We aim to review PRs promptly, but please allow a few days for feedback, especially for larger changes.

**Code of Conduct**

Please adhere to the following:

*   Be respectful and considerate in all interactions.

*   Provide constructive feedback and collaborate positively.


**Contact**

Have questions or need help? Reach out via:

*   [GitHub Issues](https://github.com/lightuponcloud/platonic-ray/issues) for bugs, features, or general inquiries.
    
*   Email: \[lightup@xentime.com (mailto:lightup@xentime.com)\] (for private matters, e.g., security issues).
    

Thank you for contributing to Platonic Ray—let’s shine a light on transparent cloud storage together!
