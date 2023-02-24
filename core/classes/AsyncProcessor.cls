public abstract without sharing class AsyncProcessor implements Database.AllowsCallouts, Database.Batchable<SObject>, Database.RaisesPlatformEvents, Process {
  private Boolean getWasCalled = false;
  private Boolean hasBeenEnqueuedAsync = false;
  private String query;
  private AsyncProcessorQueueable queueable;
  private List<Object> records;

  // hack to wrap what would have been a Queueable into a batch process:
  private static final String FALLBACK_QUERY = 'SELECT Id FROM Organization';

  @TestVisible
  private static BatchApexErrorEvent firedErrorEvent;

  public interface Process {
    String kickoff();
  }

  /**
   * Process interface-related methods
   */
  public Process get(String query) {
    return this.getProcess(query?.toLowerCase(), null);
  }

  public Process get(List<Object> records) {
    return this.getProcess(null, records);
  }

  public String kickoff() {
    this.validate();
    if (this.queueable != null && this.getCanEnqueue()) {
      return this.queueable.kickoff();
    }
    return Database.executeBatch(this, this.getBatchChunkSize());
  }

  /**
   * Batchable implementation methods, including overrideable "finish" method
   */

  public virtual Database.QueryLocator start(Database.BatchableContext bc) {
    return Database.getQueryLocator(
      this.query != null ? this.query : FALLBACK_QUERY
    );
  }

  public void execute(
    Database.BatchableContext bc,
    List<SObject> localRecords
  ) {
    this.hasBeenEnqueuedAsync = false;
    this.innerExecute(this.records != null ? this.records : localRecords);
  }

  public virtual void finish(Database.BatchableContext bc) {
  }

  // subclasses define their async processing logic using an override for "innerExecute"
  protected abstract void innerExecute(List<Object> records);

  /** Subclasses can override this method to ensure finish is only called once if recursive queueables are involved */
  protected virtual Boolean isFinished() {
    return true;
  }

  protected virtual Integer getLimitToBatch() {
    return Limits.getLimitQueryRows();
  }

  protected virtual Integer getBatchChunkSize() {
    return 2000;
  }

  protected virtual Integer getQueueableChunkSize() {
    return this.getBatchChunkSize();
  }

  private void validate() {
    if (this.getWasCalled == false) {
      throw new AsyncException(
        'Please call get() to retrieve the correct Process instance before calling kickoff'
      );
    }
  }

  private Process getProcess(String query, List<Object> records) {
    this.getWasCalled = true;
    this.records = records;
    this.query = query;

    Integer recordCount = 0;
    if (records != null) {
      recordCount = records.size();
    } else if (query != null) {
      recordCount = Database.countQuery(
        query.replace(query.substringBeforeLast(' from '), 'select count() ')
      );
    }

    Boolean shouldBatch = recordCount > this.getLimitToBatch();
    Process process = this;
    if (shouldBatch == false && this.getCanEnqueue()) {
      process = new AsyncProcessorQueueable(this);
    }
    return process;
  }

  private Boolean getCanEnqueue() {
    Integer currentQueueableCount = Limits.getQueueableJobs();
    // Sync transactions can enqueue up to 50 processes
    // but only one Queueable can be started per async transaction
    if (
      this.hasBeenEnqueuedAsync == false &&
      currentQueueableCount < Limits.getLimitQueueableJobs()
    ) {
      this.hasBeenEnqueuedAsync = this.isAsync();
      return true;
    } else if (this.isAsync()) {
      return currentQueueableCount < 1;
    } else {
      return true;
    }
  }

  private Boolean isAsync() {
    return System.isQueueable() || System.isBatch() || System.isFuture();
  }

  private class AsyncProcessorQueueable implements Database.AllowsCallouts, System.Queueable, System.Finalizer, Process {
    private final AsyncProcessor processor;
    private System.QueueableContext context;
    private Boolean hasFinalizerBeenAttached = false;

    public AsyncProcessorQueueable(AsyncProcessor processor) {
      this.processor = processor;
      this.processor.queueable = this;
    }

    public String kickoff() {
      this.processor.validate();
      if (this.processor.getCanEnqueue() == false) {
        return this.processor.kickoff();
      }
      // hack to prevent uncatchable System.AsyncException in Tests: "Maximum stack depth has been reached"
      if (this.processor.hasBeenEnqueuedAsync && Test.isRunningTest()) {
        this.execute(this.context);
        return 'Running sync';
      } else {
        return System.enqueueJob(this);
      }
    }

    public void execute(System.QueueableContext qc) {
      // once we've enqueued, it's fine to reset this flag
      this.processor.hasBeenEnqueuedAsync = false;
      if (this.hasFinalizerBeenAttached == false) {
        this.context = qc;
        this.hasFinalizerBeenAttached = true;
        System.attachFinalizer(this);
      }
      if (this.processor.records == null && this.processor.query != null) {
        this.processor.records = Database.query(this.processor.query);
      }

      List<SObject> splitRecords = this.splitProcessorRecords();
      this.processor.innerExecute(this.processor.records);
      if (splitRecords.isEmpty() == false) {
        this.processor.records.clear();
        this.processor.records.addAll(splitRecords);
        this.kickoff();
      } else if (this.processor.isFinished()) {
        this.processor.finish(new QueueableToBatchableContext(this.context));
      }
    }

    public void execute(System.FinalizerContext fc) {
      switch on fc?.getResult() {
        when UNHANDLED_EXCEPTION {
          this.fireBatchApexErrorEvent(fc);
        }
      }
    }

    private List<SObject> splitProcessorRecords() {
      List<SObject> splitRecords = new List<SObject>();
      while (
        this.processor.records.size() > this.processor.getQueueableChunkSize()
      ) {
        splitRecords.add(
          this.processor.records.remove(this.processor.records.size() - 1)
        );
      }
      return splitRecords;
    }

    private void fireBatchApexErrorEvent(System.FinalizerContext fc) {
      String fullLengthJobScope = String.join(this.getRecordsInScope(), ',');
      Integer jobScopeLengthLimit = 40000;
      Integer textFieldLengthLimit = 5000;
      // initializing a BatchApexErrorEvent works as of Spring 23
      // but we can't promise it always will - use accordingly!
      BatchApexErrorEvent errorEvent = new BatchApexErrorEvent(
        AsyncApexJobId = fc.getAsyncApexJobId(),
        DoesExceedJobScopeMaxLength = fullLengthJobScope.length() >
          jobScopeLengthLimit,
        ExceptionType = fc.getException().getTypeName(),
        JobScope = this.getSafeSubstring(
            fullLengthJobScope,
            jobScopeLengthLimit
          )
          .removeEnd(','),
        Message = this.getSafeSubstring(
          fc.getException().getMessage(),
          textFieldLengthLimit
        ),
        Phase = 'EXECUTE',
        StackTrace = this.getSafeSubstring(
          fc.getException().getStacktraceString(),
          textFieldLengthLimit
        )
      );

      Database.SaveResult publishResult = EventBus.publish(errorEvent);
      if (publishResult.isSuccess()) {
        firedErrorEvent = errorEvent;
      }
    }

    private List<String> getRecordsInScope() {
      List<String> scope = new List<String>();
      if (this.processor.records instanceof List<SObject>) {
        for (
          Id recordId : new Map<Id, SObject>(
              (List<SObject>) this.processor.records
            )
            .keySet()
        ) {
          scope.add(recordId);
        }
      }
      return scope;
    }

    private String getSafeSubstring(String target, Integer maxLength) {
      return target.length() > maxLength
        ? target.substring(0, maxLength)
        : target;
    }
  }

  private class QueueableToBatchableContext implements Database.BatchableContext {
    private final Id jobId;

    public QueueableToBatchableContext(System.QueueableContext qc) {
      this.jobId = qc.getJobId();
    }

    public Id getJobId() {
      return this.jobId;
    }

    public Id getChildJobId() {
      return null;
    }
  }
}
