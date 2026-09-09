import 'package:json_annotation/json_annotation.dart';

part 'model_383.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model383 {
  const Model383({required this.id, required this.value});

  final int id;
  final String value;

  factory Model383.fromJson(Map<String, dynamic> json) =>
      _$Model383FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model383ToJson(this);
}
