import 'package:json_annotation/json_annotation.dart';

part 'model_039.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model039 {
  const Model039({required this.id, required this.value});

  final int id;
  final String value;

  factory Model039.fromJson(Map<String, dynamic> json) =>
      _$Model039FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model039ToJson(this);
}
