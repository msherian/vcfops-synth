@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # The CLI writes progress and results for a person at a terminal.
        'PSAvoidUsingWriteHost'
    )
}
