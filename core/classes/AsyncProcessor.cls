public abstract without sharing class AsyncProcessor implements Database.AllowsCallouts, Database.Batchable<SObject>, Database.RaisesPlatformEvents, Process {
  private Boolean getWasCalled = false;
  private Boolean hasBeenEnqueuedAsync = false;
  private String query;
  private AsyncProcessorQueueable queueable;

  protected List<SObject> records;
  private final List<SObject> chunkRecords = new List<SObject>();

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

  public Process get(List<SObject> records) {
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

  public Database.QueryLocator start(Database.BatchableContext bc) {
    return Database.getQueryLocator(this.query ?? FALLBACK_QUERY);
  }

  public void execute(
    Database.BatchableContext bc,
    List<SObject> localRecords
  ) {
    this.hasBeenEnqueuedAsync = false;
    Integer chunkSize = this.getBatchChunkSize();
    if (this.query == null && this.records != null) {
      while (this.records.size() > chunkSize) {
        this.chunkRecords.add(this.records.remove(this.records.size() - 1));
      }
    }
    this.innerExecute(this.records ?? localRecords);
    if (this.chunkRecords.isEmpty() == false) {
      this.records = new List<SObject>(this.chunkRecords);
      this.kickoff();
    }
  }

  public virtual void finish(Database.BatchableContext bc) {
  }

  /** Subclasses define their async processing logic using an override for "innerExecute"**/
  protected abstract void innerExecute(List<SObject> records);

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
    return this.records?.size() ?? this.getBatchChunkSize();
  }

  private void validate() {
    if (this.getWasCalled == false) {
      throw new AsyncException(
        'Please call get() to retrieve the correct Process instance before calling kickoff'
      );
    } else if (
      System.isBatch() &&
      this.queueable == null &&
      this.chunkRecords.isEmpty() == false
    ) {
      this.queueable = new AsyncProcessorQueueable(this);
      this.chunkRecords.clear();
    }
  }

  private Process getProcess(String query, List<SObject> records) {
    this.getWasCalled = true;
    this.records = records;
    this.query = query;

    Integer recordCount = query == null
      ? records.size()
      : this.getRecordCount(query);
    Boolean shouldBatch = recordCount > this.getLimitToBatch();
    Process process = this;
    if (shouldBatch == false && this.getCanEnqueue()) {
      process = new AsyncProcessorQueueable(this);
    }
    return process;
  }

  private Integer getRecordCount(String query) {
    String countQuery = query.replace(
      query.substringBeforeLast(' from '),
      'select count() '
    );
    Integer possibleOrderStatement = query.lastIndexOfIgnoreCase('order by');
    if (possibleOrderStatement > -1) {
      countQuery = countQuery.replace(
        query.substring(possibleOrderStatement),
        ''
      );
    }
    return Database.countquery(countQuery);
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
    private Boolean hasFinalizerBeenAttached = false;
    private Boolean shouldRequeue = false;

    public AsyncProcessorQueueable(AsyncProcessor processor) {
      this.processor = processor;
      this.processor.queueable = this;
    }

    public String kickoff() {
      this.processor.validate();
      if (this.processor.getCanEnqueue() == false) {
        return this.processor.kickoff();
      }
      this.hasFinalizerBeenAttached = false;

      return System.enqueueJob(this);
    }

    public void execute(System.QueueableContext qc) {
      // once we've enqueued, it's fine to reset this flag
      this.processor.hasBeenEnqueuedAsync = false;

      if (this.hasFinalizerBeenAttached == false) {
        this.hasFinalizerBeenAttached = true;
        System.attachFinalizer(this);
      }
      if (this.processor.records == null && this.processor.query != null) {
        this.processor.records = Database.query(this.processor.query);
      }

      List<SObject> splitRecords = this.splitProcessorRecords();
      this.processor.innerExecute(this.processor.records);

      if (splitRecords.isEmpty() == false) {
        this.shouldRequeue = true;
        this.processor.records.clear();
        this.processor.records.addAll(splitRecords);
      } else if (this.processor.isFinished()) {
        this.processor.finish(new QueueableToBatchableContext(qc));
      }
    }

    public void execute(System.FinalizerContext fc) {
      switch on fc?.getResult() {
        when UNHANDLED_EXCEPTION {
          this.fireBatchApexErrorEvent(fc);
        }
        when else {
          if (this.shouldRequeue) {
            this.shouldRequeue = false;
            this.kickoff();
          }
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
      for (
        Id recordId : new Map<Id, SObject>(this.processor.records).keySet()
      ) {
        scope.add(recordId);
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
