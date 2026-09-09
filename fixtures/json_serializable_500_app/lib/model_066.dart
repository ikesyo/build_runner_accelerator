import 'package:json_annotation/json_annotation.dart';

part 'model_066.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model066 {
  const Model066({required this.id, required this.value});

  final int id;
  final String value;

  factory Model066.fromJson(Map<String, dynamic> json) =>
      _$Model066FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model066ToJson(this);
}
