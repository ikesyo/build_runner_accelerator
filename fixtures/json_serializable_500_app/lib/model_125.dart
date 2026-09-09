import 'package:json_annotation/json_annotation.dart';

part 'model_125.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model125 {
  const Model125({required this.id, required this.value});

  final int id;
  final String value;

  factory Model125.fromJson(Map<String, dynamic> json) =>
      _$Model125FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model125ToJson(this);
}
