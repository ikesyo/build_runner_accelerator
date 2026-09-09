import 'package:json_annotation/json_annotation.dart';

part 'model_344.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model344 {
  const Model344({required this.id, required this.value});

  final int id;
  final String value;

  factory Model344.fromJson(Map<String, dynamic> json) =>
      _$Model344FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model344ToJson(this);
}
