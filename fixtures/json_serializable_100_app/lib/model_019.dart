import 'package:json_annotation/json_annotation.dart';

part 'model_019.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model019 {
  const Model019({required this.id, required this.value});

  final int id;
  final String value;

  factory Model019.fromJson(Map<String, dynamic> json) =>
      _$Model019FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model019ToJson(this);
}
