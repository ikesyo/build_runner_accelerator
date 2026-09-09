import 'package:json_annotation/json_annotation.dart';

part 'model_350.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model350 {
  const Model350({required this.id, required this.value});

  final int id;
  final String value;

  factory Model350.fromJson(Map<String, dynamic> json) =>
      _$Model350FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model350ToJson(this);
}
