import 'package:json_annotation/json_annotation.dart';

part 'model_443.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model443 {
  const Model443({required this.id, required this.value});

  final int id;
  final String value;

  factory Model443.fromJson(Map<String, dynamic> json) =>
      _$Model443FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model443ToJson(this);
}
