# Apex Async Processor

This repository showcases how to use the `AsyncProcessor` pattern to avoid having to create batch classes and/or queueable classes.

Using this pattern greatly simplifies how asynchronous code is defined and run on platform. Simply:

- clone the repository or copy/paste the [AsyncProcessor](../../blob/main/core/classes/AsyncProcessor.cls) and [AsyncProcessorTests](../../blob/main/core/classes/AsyncProcessorTests.cls) files to your org
- extend the `AsyncProcessor`, defining code you'd like to have processed asynchronously:

  - also add any additional interfaces you need, like `Database.Stateful` (as is appropriate)

  ```java
  public class AsyncContactProcessorExample extends AsyncProcessor {
    protected override void innerExecute(List<Object> records) {
      List<Contact> contacts = (List<Contact>) records;
      // do whatever processing here
    }
  }
  ```

  - and then in usage:

  ```java
  // within some other class:
  new AsyncContactProcessorExample().get('SELECT Id, Account.Name FROM Contact').kickoff();
  // or, alternatively, if you have the records already:
  new AsyncContactProcessorExample().get(contacts).kickoff();
  ```

For query-based usages, `AsyncProcessor` will automatically choose whether to batch or enqueue based on the default returned by `Limits.getLimitQueryRows()` - this can also be overridden by providing an alternative implementation of `protected virtual Integer getLimitToBatch()` for subclasses of `AsyncProcessor`.

## Further Examples

Here's an example lowering the `getLimitToBatch()` amount from 50k to 10k records. This could be really useful if the data you're passing in might otherwise blow up the heap size limit.

```java
public without sharing class LowerLimitAsyncProcessor {

  public override Integer getLimitToBatch() {
    return Limits.getLimitDmlRows();
  }
}
```

You can also look at [ContactAsyncProcessor](../../blob/main/example-app/classes/ContactAsyncProcessor.cls) for a short, complete example.
