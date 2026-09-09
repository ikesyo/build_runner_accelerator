import 'package:json_annotation/json_annotation.dart';

part 'model_034.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model034 {
  const Model034({required this.id, required this.value});

  final int id;
  final String value;

  factory Model034.fromJson(Map<String, dynamic> json) =>
      _$Model034FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model034ToJson(this);
}
